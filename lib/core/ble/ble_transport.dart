import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' hide LogLevel;
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart'
    show SpanKind;

import '../protocol/codec.dart';
import '../protocol/opcodes.dart';
import '../services/app_log.dart';
import '../services/opentelemetry_service.dart';
import 'ble_constants.dart';
import 'fee7_service.dart';

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
class BleTransport implements Fee7Host {
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
  final _inboundFee7 = StreamController<Uint8List>.broadcast();

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

  /// Inbound 16-byte frames received on the vendor `0xFEE7` notify
  /// characteristic. Emits only after the characteristic has been discovered
  /// and notifications enabled (i.e. once `_fee7Notify` is non-null); no-op
  /// for watches that do not expose the service.
  @override
  Stream<Uint8List> get fee7Inbound => _inboundFee7.stream;

  BluetoothDevice? get device => _device;
  bool get isReady => _state.value == LinkState.ready;

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> connect(
    BluetoothDevice device, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    // Trace the full GATT connect handshake: from disconnecting any prior
    // link through service discovery, notify-enable, and device-info read.
    final span = OpenTelemetryService().startTrace(
      'ble.connect',
      kind: SpanKind.client,
      attributes: {
        'ble.device.id': device.remoteId.str,
        'ble.device.name': device.platformName,
        'ble.timeout_ms': timeout.inMilliseconds,
      },
    );
    var ok = false;
    try {
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
      if (_fee7Notify != null) {
        await _fee7Notify!.setNotifyValue(true);
        _subs.add(_fee7Notify!.onValueReceived.listen(_onFee7));
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
      ok = true;
    } finally {
      span?.end(ok: ok);
    }
  }

  Future<void> _readDeviceInfo(List<BluetoothService> services) async {
    // Group the optional Device-Info GATT reads (hw/fw revision) under a
    // single span so each connect's handshake cost is visible at a glance.
    final span = OpenTelemetryService().startTrace(
      'ble.read_device_info',
      kind: SpanKind.internal,
    );
    try {
      final info = services
          .where((s) => s.uuid == BleUuids.deviceInfo)
          .toList();
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
    } finally {
      span?.end();
    }
  }

  void _onChannelA(List<int> data) {
    // Inbound Channel-A frame: traced as a consumer-side notification so
    // latency from GATT notify to the dispatcher is measurable.
    final span = OpenTelemetryService().startTrace(
      'ble.rx',
      kind: SpanKind.consumer,
      attributes: {'ble.channel': 'A', 'ble.frame.length': data.length},
    );
    try {
      _onChannelATraced(data, span);
    } finally {
      span?.end();
    }
  }

  void _onChannelATraced(List<int> data, OTelSpan? span) {
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
    // Inbound Channel-B frame (large data); traced as a consumer so we can
    // see chunk rate + size distribution.
    final span = OpenTelemetryService().startTrace(
      'ble.rx',
      kind: SpanKind.consumer,
      attributes: {'ble.channel': 'B', 'ble.frame.length': data.length},
    );
    try {
      _log.frame('rx', 'RX-B', data);
      _inboundB.add(Uint8List.fromList(data));
    } finally {
      span?.end();
    }
  }

  void _onFee7(List<int> data) {
    // Inbound vendor 0xFEE7 frame; one span per notification so the fee7
    // dispatcher can be monitored independently of the canonical channels.
    final span = OpenTelemetryService().startTrace(
      'ble.rx',
      kind: SpanKind.consumer,
      attributes: {'ble.channel': 'fee7', 'ble.frame.length': data.length},
    );
    try {
      final frame = Uint8List.fromList(data);
      if (!Codec.isValidChannelA(frame)) {
        _log.frame(
          'rx',
          'RX-FEE7(DROPPED len=${frame.length})',
          data,
          level: LogLevel.warn,
        );
        return;
      }
      // Use rxOpcodeRaw — fee7 opcodes are dense in 0x80..0xff where the
      // top bit is part of the opcode namespace, not an error indicator.
      final opcode = Codec.rxOpcodeRaw(frame);
      _log.frame('rx', 'RX-FEE7 op=0x${opcode.toRadixString(16)}', data);
      _inboundFee7.add(frame);
    } finally {
      span?.end();
    }
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
    // Synchronous request/response RPC: outbound write + inbound wait.
    // Traced as a client span so per-opcode latency and timeout rates
    // are visible in the trace backend.
    final opcode = frame[0] & ~Codec.errorFlag;
    final span = OpenTelemetryService().startTrace(
      'ble.request',
      kind: SpanKind.client,
      attributes: {
        'ble.opcode': (frame[0] & 0xFF).toRadixString(16),
        'ble.timeout_ms': timeout.inMilliseconds,
      },
    );
    var ok = false;
    try {
      _requireReady();
      final completer = Completer<Uint8List>();
      (_pending[opcode] ??= []).add(completer);
      _log.frame(
        'tx',
        'TX-A op=0x${opcode.toRadixString(16)} (await resp)',
        frame,
      );
      await _enqueue(_WriteOp(_writeA!, frame, withoutResponse: false));
      try {
        final result = await completer.future.timeout(timeout);
        ok = true;
        return result;
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
    } catch (e, stack) {
      span?.recordError(e, stack);
      rethrow;
    } finally {
      span?.end(ok: ok);
    }
  }

  // ---------------------------------------------------------------------------
  // Channel B: large data (sliced, write-without-response)
  // ---------------------------------------------------------------------------

  /// Sends a fully-framed Channel-B buffer, sliced into [packageLength] chunks.
  Future<void> sendB(Uint8List framed) async {
    // Channel-B bulk transfer: spans the whole sliced send so we can
    // correlate total bytes and chunk count against downstream OTA speed.
    final span = OpenTelemetryService().startTrace(
      'ble.sendB',
      kind: SpanKind.client,
      attributes: {'ble.frame.length': framed.length},
    );
    var ok = false;
    try {
      final char = _writeB;
      if (char == null) {
        throw const BleTransportException(
          'Channel B not available on this device',
        );
      }
      var frames = 0;
      for (var off = 0; off < framed.length; off += packageLength) {
        final end = (off + packageLength < framed.length)
            ? off + packageLength
            : framed.length;
        final chunk = Uint8List.sublistView(framed, off, end);
        await _enqueue(_WriteOp(char, chunk, withoutResponse: true));
        frames++;
      }
      span?.setAttribute('ble.frames_total', frames);
      ok = true;
    } catch (e, stack) {
      span?.recordError(e, stack);
      rethrow;
    } finally {
      span?.end(ok: ok);
    }
  }

  // ---------------------------------------------------------------------------
  // Vendor 0xFEE7 command channel (parallel 16-byte command path)
  // ---------------------------------------------------------------------------

  /// Whether the vendor `0xFEE7` write characteristic was discovered.
  @override
  bool get hasFee7Write => _fee7Write != null;

  /// Sends a 16-byte frame on the vendor `0xFEE7` service. The frame is
  /// expected to be already checksummed (use [Codec.buildChannelA]).
  ///
  /// Throws if the device did not advertise the `0xFEE7` write characteristic.
  @override
  Future<void> sendFee7(Uint8List frame) {
    final char = _fee7Write;
    if (char == null) {
      throw const BleTransportException(
        'Vendor 0xFEE7 write characteristic not available',
      );
    }
    if (!Codec.isValidChannelA(frame)) {
      throw const BleTransportException(
        '0xFEE7 frame must be 16 bytes with valid additive checksum',
      );
    }
    _log.frame('tx', 'TX-FEE7 op=0x${frame[0].toRadixString(16)}', frame);
    return _enqueue(_WriteOp(char, frame, withoutResponse: false));
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
        // One child span per GATT write so a slow characteristic shows up
        // in the trace timeline. Attributes identify which channel wrote
        // and whether the write expects a response.
        final span = OpenTelemetryService().startTrace(
          'ble.gatt.write',
          kind: SpanKind.internal,
          attributes: {
            'ble.characteristic.uuid': op.characteristic.uuid.str,
            'ble.frame.length': op.value.length,
            'ble.write.withResponse': !op.withoutResponse,
          },
        );
        var ok = false;
        try {
          final noResp =
              op.withoutResponse &&
              op.characteristic.properties.writeWithoutResponse;
          await op.characteristic
              .write(op.value, withoutResponse: noResp)
              .timeout(const Duration(seconds: 5));
          op.completer.complete();
          ok = true;
        } catch (e, stack) {
          span?.recordError(e, stack);
          _log.error('tx', 'GATT write failed: $e');
          if (!op.completer.isCompleted) op.completer.completeError(e);
        } finally {
          span?.end(ok: ok);
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
    // Trace the full teardown path: subscription cancel, GATT disconnect,
    // characteristic reset, state notification.
    final span = OpenTelemetryService().startTrace(
      'ble.disconnect',
      kind: SpanKind.client,
    );
    var ok = false;
    try {
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
      ok = true;
    } catch (e, stack) {
      span?.recordError(e, stack);
      rethrow;
    } finally {
      span?.end(ok: ok);
    }
  }

  void dispose() {
    _state.dispose();
    unawaited(_inboundA.close());
    unawaited(_inboundB.close());
    unawaited(_inboundFee7.close());
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
