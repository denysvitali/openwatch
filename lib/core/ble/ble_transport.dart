import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../protocol/codec.dart';
import '../protocol/opcodes.dart';
import 'ble_constants.dart';

/// Connection lifecycle of the watch link.
enum LinkState {
  disconnected,
  connecting,
  discovering,
  readingDeviceInfo,
  ready,
}

/// GATT transport for the Oudmon two-channel protocol.
///
/// * Channel A — 16-byte commands, write-with-response, opcode-correlated
///   responses, gated behind [isReady].
/// * Channel B — `0xBC`-framed large data, write-without-response, sliced into
///   [packageLength]-byte chunks.
///
/// All writes funnel through a single serialized queue: at most one GATT
/// operation is in flight at a time (mirroring the firmware's `notifyLock`).
class BleTransport {
  BleTransport();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeA;
  BluetoothCharacteristic? _notifyA;
  BluetoothCharacteristic? _writeB;
  BluetoothCharacteristic? _notifyB;

  final _subs = <StreamSubscription<dynamic>>[];
  final _state = ValueNotifier<LinkState>(LinkState.disconnected);
  final _inboundA = StreamController<Uint8List>.broadcast();
  final _inboundB = StreamController<Uint8List>.broadcast();

  // Serialized write queue.
  final Queue<_WriteOp> _queue = Queue<_WriteOp>();
  bool _draining = false;

  // Opcode-correlated single-response waiters for Channel A.
  final Map<int, Completer<Uint8List>> _pending = {};

  int packageLength = BleUuids.defaultPackageLength;
  String hardwareRevision = '';
  String firmwareRevision = '';

  ValueListenable<LinkState> get state => _state;
  Stream<Uint8List> get inboundA => _inboundA.stream;
  Stream<Uint8List> get inboundB => _inboundB.stream;
  BluetoothDevice? get device => _device;
  bool get isReady => _state.value == LinkState.ready;

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> connect(
    BluetoothDevice device, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await disconnect();
    _device = device;
    _state.value = LinkState.connecting;

    _subs.add(
      device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      }),
    );

    await device.connect(timeout: timeout, autoConnect: false);

    _state.value = LinkState.discovering;
    final services = await device.discoverServices();

    for (final svc in services) {
      if (svc.uuid == BleUuids.serviceA) {
        for (final c in svc.characteristics) {
          if (c.uuid == BleUuids.writeA) _writeA = c;
          if (c.uuid == BleUuids.notifyA) _notifyA = c;
        }
      } else if (svc.uuid == BleUuids.serviceB) {
        for (final c in svc.characteristics) {
          if (c.uuid == BleUuids.writeB) _writeB = c;
          if (c.uuid == BleUuids.notifyB) _notifyB = c;
        }
      }
    }
    if (_writeA == null || _notifyA == null) {
      throw const BleTransportException(
        'Channel-A command characteristics not found',
      );
    }

    await _notifyA!.setNotifyValue(true);
    _subs.add(_notifyA!.onValueReceived.listen(_onChannelA));
    if (_notifyB != null) {
      await _notifyB!.setNotifyValue(true);
      _subs.add(_notifyB!.onValueReceived.listen(_onChannelB));
    }

    // Handshake: read hardware then firmware revision; ready once both return.
    _state.value = LinkState.readingDeviceInfo;
    await _readDeviceInfo(services);
    _state.value = LinkState.ready;
  }

  Future<void> _readDeviceInfo(List<BluetoothService> services) async {
    final info = services.where((s) => s.uuid == BleUuids.deviceInfo).toList();
    if (info.isEmpty) return;
    for (final c in info.first.characteristics) {
      try {
        if (c.uuid == BleUuids.hardwareRevision) {
          hardwareRevision = String.fromCharCodes(await c.read()).trim();
        } else if (c.uuid == BleUuids.firmwareRevision) {
          firmwareRevision = String.fromCharCodes(await c.read()).trim();
        }
      } catch (_) {
        // Device-info reads are best-effort; absence must not block readiness.
      }
    }
  }

  void _onChannelA(List<int> data) {
    final frame = Uint8List.fromList(data);
    if (!Codec.isValidChannelA(frame)) return;
    final opcode = Codec.rxOpcode(frame);

    // Persistent push: PackageLength negotiation for Channel B.
    if (opcode == OpA.packageLength) {
      final v = frame[1] & 0xFF;
      packageLength = v > BleUuids.defaultPackageLength
          ? v
          : BleUuids.defaultPackageLength;
    }

    final waiter = _pending.remove(opcode);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(frame);
    }
    _inboundA.add(frame);
  }

  void _onChannelB(List<int> data) {
    _inboundB.add(Uint8List.fromList(data));
  }

  // ---------------------------------------------------------------------------
  // Channel A: commands
  // ---------------------------------------------------------------------------

  /// Sends a Channel-A command frame (fire-and-forget). Rejected before ready.
  Future<void> sendA(Uint8List frame) {
    _requireReady();
    return _enqueue(_WriteOp(_writeA!, frame, withoutResponse: false));
  }

  /// Sends a Channel-A command and waits for the matching opcode response.
  /// Returns the first matching 16-byte frame, or throws on timeout.
  Future<Uint8List> requestA(
    Uint8List frame, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _requireReady();
    final opcode = frame[0] & ~Codec.errorFlag;
    final completer = Completer<Uint8List>();
    _pending[opcode] = completer;
    await _enqueue(_WriteOp(_writeA!, frame, withoutResponse: false));
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(opcode);
    }
  }

  // ---------------------------------------------------------------------------
  // Channel B: large data (sliced, write-without-response)
  // ---------------------------------------------------------------------------

  /// Sends a fully-framed Channel-B buffer, sliced into [packageLength] chunks.
  Future<void> sendB(Uint8List framed) async {
    final char = _writeB;
    if (char == null) {
      throw const BleTransportException(
        'Channel B not available on this device',
      );
    }
    for (var off = 0; off < framed.length; off += packageLength) {
      final end = (off + packageLength < framed.length)
          ? off + packageLength
          : framed.length;
      final chunk = Uint8List.sublistView(framed, off, end);
      await _enqueue(_WriteOp(char, chunk, withoutResponse: true));
    }
  }

  // ---------------------------------------------------------------------------
  // Serialized queue
  // ---------------------------------------------------------------------------

  Future<void> _enqueue(_WriteOp op) {
    _queue.add(op);
    if (!_draining) unawaited(_drain());
    return op.completer.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final op = _queue.removeFirst();
        try {
          final noResp =
              op.withoutResponse &&
              op.characteristic.properties.writeWithoutResponse;
          await op.characteristic
              .write(op.value, withoutResponse: noResp)
              .timeout(const Duration(seconds: 5));
          op.completer.complete();
        } catch (e) {
          if (!op.completer.isCompleted) op.completer.completeError(e);
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    } finally {
      _draining = false;
    }
  }

  void _requireReady() {
    if (!isReady) {
      throw const BleTransportException('Link not ready (init not complete)');
    }
  }

  // ---------------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------------

  void _onDisconnected() {
    for (final c in _pending.values) {
      if (!c.isCompleted)
        c.completeError(const BleTransportException('Disconnected'));
    }
    _pending.clear();
    _queue.clear();
    _draining = false;
    _state.value = LinkState.disconnected;
  }

  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _onDisconnected();
    final d = _device;
    _device = null;
    _writeA = _notifyA = _writeB = _notifyB = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    _state.value = LinkState.disconnected;
  }

  void dispose() {
    _state.dispose();
    unawaited(_inboundA.close());
    unawaited(_inboundB.close());
  }
}

class _WriteOp {
  _WriteOp(this.characteristic, this.value, {required this.withoutResponse});
  final BluetoothCharacteristic characteristic;
  final Uint8List value;
  final bool withoutResponse;
  final Completer<void> completer = Completer<void>();
}

class BleTransportException implements Exception {
  const BleTransportException(this.message);
  final String message;
  @override
  String toString() => 'BleTransportException: $message';
}
