import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide LogLevel;

import '../protocol/codec.dart';
import '../protocol/opcodes.dart';
import '../services/app_log.dart';
import 'ble_constants.dart';

final _log = AppLog.instance;

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
  // Probe-only: vendor fee7 service + Device Name char. Currently logged at
  // connect time; reserved for future alternate OTA/command paths (see
  // `firmwares/R2_ANALYSIS.md` §7).
  BluetoothCharacteristic? _fee7Write;
  BluetoothCharacteristic? _fee7Read;
  BluetoothCharacteristic? _fee7Notify;
  BluetoothCharacteristic? _deviceName;

  final _subs = <StreamSubscription<dynamic>>[];
  final _state = ValueNotifier<LinkState>(LinkState.disconnected);
  final _inboundA = StreamController<Uint8List>.broadcast();
  final _inboundB = StreamController<Uint8List>.broadcast();

  // Serialized write queue.
  final Queue<_WriteOp> _queue = Queue<_WriteOp>();
  bool _draining = false;

  // Opcode-correlated response waiters for Channel A (FIFO per opcode, so
  // overlapping requests for the same opcode don't clobber each other).
  final Map<int, List<Completer<Uint8List>>> _pending = {};

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

    _log.info(
      'ble',
      'Connecting to ${device.remoteId.str} '
          '(${device.platformName.isEmpty ? "?" : device.platformName})',
    );
    await device.connect(timeout: timeout, autoConnect: false);
    _log.info('ble', 'Connected; discovering services');

    _state.value = LinkState.discovering;
    final services = await device.discoverServices();
    _log.debug(
      'ble',
      'Services: ${services.map((s) => s.uuid.str).join(", ")}',
    );

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
      } else if (svc.uuid == BleUuids.serviceFee7) {
        // Vendor 0xfee7 service: probe-only. Logging which characteristics the
        // firmware actually declared lets us detect future OEM-specific OTA or
        // command paths without breaking the canonical Channel-A/B flow.
        for (final c in svc.characteristics) {
          if (c.uuid == BleUuids.fee7Write) _fee7Write = c;
          if (c.uuid == BleUuids.fee7Read) _fee7Read = c;
          if (c.uuid == BleUuids.fee7Notify) _fee7Notify = c;
          if (c.uuid == BleUuids.deviceName) _deviceName = c;
        }
      } else if (svc.uuid == BleUuids.deviceInfo) {
        for (final c in svc.characteristics) {
          if (c.uuid == BleUuids.deviceName) _deviceName = c;
        }
      }
    }
    _log.info(
      'ble',
      'Chars: writeA=${_writeA != null} notifyA=${_notifyA != null} '
          'writeB=${_writeB != null} notifyB=${_notifyB != null} '
          'fee7=${_fee7Write != null || _fee7Read != null || _fee7Notify != null} '
          'devName=${_deviceName != null}',
    );
    if (_writeA == null || _notifyA == null) {
      throw const BleTransportException(
        'Channel-A command characteristics not found',
      );
    }
    _log.debug(
      'ble',
      'writeA props: wr=${_writeA!.properties.write} '
          'wrNoResp=${_writeA!.properties.writeWithoutResponse} '
          'notify=${_notifyA!.properties.notify} indicate=${_notifyA!.properties.indicate}',
    );

    await _notifyA!.setNotifyValue(true);
    _subs.add(_notifyA!.onValueReceived.listen(_onChannelA));
    if (_notifyB != null) {
      await _notifyB!.setNotifyValue(true);
      _subs.add(_notifyB!.onValueReceived.listen(_onChannelB));
    }
    _log.info('ble', 'Notifications enabled');

    // Handshake: read hardware then firmware revision; ready once both return.
    _state.value = LinkState.readingDeviceInfo;
    await _readDeviceInfo(services);
    _state.value = LinkState.ready;
    _log.info(
      'ble',
      'Link READY (hw="$hardwareRevision" fw="$firmwareRevision")',
    );
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
      } catch (e) {
        // Device-info reads are best-effort; absence must not block readiness.
        _log.warn('ble', 'Device-info read failed for ${c.uuid.str}: $e');
      }
    }
  }

  void _onChannelA(List<int> data) {
    final frame = Uint8List.fromList(data);
    final valid = Codec.isValidChannelA(frame);
    if (!valid) {
      // Log the raw bytes so a checksum/length mismatch is diagnosable.
      final expected = frame.length >= 16
          ? (frame.sublist(0, 15).fold<int>(0, (a, b) => a + b) & 0xFF)
          : -1;
      _log.frame(
        'rx',
        'RX-A(DROPPED len=${frame.length}'
            '${frame.length == 16 ? " cksum got=0x${frame[15].toRadixString(16)} want=0x${expected.toRadixString(16)}" : ""})',
        data,
        level: LogLevel.warn,
      );
      return;
    }
    final opcode = Codec.rxOpcode(frame);
    _log.frame(
      'rx',
      'RX-A op=0x${opcode.toRadixString(16)}'
          '${Codec.rxIsError(frame) ? " ERR" : ""}',
      data,
    );

    // Persistent push: PackageLength negotiation for Channel B.
    if (opcode == OpA.packageLength) {
      final v = frame[1] & 0xFF;
      packageLength = v > BleUuids.defaultPackageLength
          ? v
          : BleUuids.defaultPackageLength;
    }

    final waiters = _pending[opcode];
    if (waiters != null && waiters.isNotEmpty) {
      final waiter = waiters.removeAt(0);
      if (waiters.isEmpty) _pending.remove(opcode);
      if (!waiter.isCompleted) waiter.complete(frame);
    }
    _inboundA.add(frame);
  }

  void _onChannelB(List<int> data) {
    _log.frame('rx', 'RX-B', data);
    _inboundB.add(Uint8List.fromList(data));
  }

  // ---------------------------------------------------------------------------
  // Channel A: commands
  // ---------------------------------------------------------------------------

  /// Sends a Channel-A command frame (fire-and-forget). Rejected before ready.
  Future<void> sendA(Uint8List frame) {
    _requireReady();
    _log.frame('tx', 'TX-A op=0x${frame[0].toRadixString(16)}', frame);
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
    (_pending[opcode] ??= []).add(completer);
    _log.frame(
      'tx',
      'TX-A op=0x${opcode.toRadixString(16)} (await resp)',
      frame,
    );
    await _enqueue(_WriteOp(_writeA!, frame, withoutResponse: false));
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _log.error(
        'tx',
        'No response to op=0x${opcode.toRadixString(16)} '
            'within ${timeout.inSeconds}s',
      );
      rethrow;
    } finally {
      _pending[opcode]?.remove(completer);
      if (_pending[opcode]?.isEmpty ?? false) _pending.remove(opcode);
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
          _log.error('tx', 'GATT write failed: $e');
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
    for (final waiters in _pending.values) {
      for (final c in waiters) {
        if (!c.isCompleted) {
          c.completeError(const BleTransportException('Disconnected'));
        }
      }
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
    _fee7Write = _fee7Read = _fee7Notify = _deviceName = null;
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
