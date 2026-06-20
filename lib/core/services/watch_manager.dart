import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../protocol/capabilities.dart';
import '../protocol/codec.dart';
import '../protocol/commands.dart';
import '../protocol/hr_parser.dart';
import '../protocol/opcodes.dart';
import 'app_log.dart';
import 'protocol_hub.dart';

/// High-level device manager: runs the post-connect handshake (time sync +
/// capability probe), keeps live device state, and exposes management actions.
///
/// Sits on top of [BleTransport] and is fully local — no cloud involvement.
class WatchManager extends ChangeNotifier {
  WatchManager(this._transport, {this.autoSyncTime = true}) {
    _transport.state.addListener(_onLinkState);
    _inboundSub = _transport.inboundA.listen(_onFrame);
    _hub = ProtocolHub(_transport);
    _hub.ancs.events.listen(_onAncsEvent);
    _onLinkState();
  }

  final BleTransport _transport;
  bool autoSyncTime;
  StreamSubscription<Uint8List>? _inboundSub;
  late final ProtocolHub _hub;
  LinkState _last = LinkState.disconnected;
  bool _handshaking = false;
  Timer? _stepTimer;
  Timer? _batteryTimer;

  DeviceCapabilities capabilities = const DeviceCapabilities();
  int? batteryPercent;
  bool charging = false;
  int? todaySteps;
  int? todayCalories;
  int? todayDistanceMeters;
  int? lastHeartRate;
  bool initialized = false;

  String get hardwareRevision => _transport.hardwareRevision;
  String get firmwareRevision => _transport.firmwareRevision;
  bool get isReady => _transport.isReady;

  void _onLinkState() {
    final s = _transport.state.value;
    if (s == LinkState.ready && _last != LinkState.ready) {
      unawaited(_runHandshake());
    }
    if (s == LinkState.disconnected) {
      initialized = false;
      _handshaking = false;
      _stepTimer?.cancel();
      _batteryTimer?.cancel();
      _stepTimer = null;
      _batteryTimer = null;
    }
    _last = s;
    notifyListeners();
  }

  void _startTimers() {
    _stepTimer?.cancel();
    _batteryTimer?.cancel();
    _stepTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => refreshSteps(),
    );
    _batteryTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => refreshBattery(),
    );
  }

  Future<void> _runHandshake() async {
    if (_handshaking || initialized) return;
    _handshaking = true;
    AppLog.instance.info(
      'watch',
      'Handshake start (autoSyncTime=$autoSyncTime)',
    );
    try {
      if (autoSyncTime) {
        await _transport.sendA(Commands.setTime(DateTime.now()));
      }
      final support = await _transport.requestA(Commands.deviceSupport());
      capabilities = capabilities.mergeSupport(Codec.rxPayload(support));
      AppLog.instance.info(
        'watch',
        'Capabilities: hr=${capabilities.heart} spo2=${capabilities.bloodOxygen} '
            'bp=${capabilities.bloodPressure} sleep=${capabilities.sleep} '
            'alarm=${capabilities.alarm} screen=${capabilities.screenWidth}x${capabilities.screenHeight}',
      );
      // Fire-and-forget for the periodic stats — but wait briefly so the
      // initial replies land before we declare "ready" to the UI.
      final fresh = DateTime.now();
      await Future.wait([
        refreshSteps(),
        refreshBattery(),
        _waitForReplies(const Duration(milliseconds: 400), {
          OpA.todaySport,
          OpA.battery,
        }),
      ]);
      // Touch `fresh` so the analyzer is happy if we ever drop the call.
      fresh.toString();
      _startTimers();
      initialized = true;
      notifyListeners();
      AppLog.instance.info('watch', 'Handshake complete');
    } catch (e) {
      AppLog.instance.error('watch', 'Handshake failed: $e');
    } finally {
      _handshaking = false;
    }
  }

  void _onFrame(Uint8List frame) {
    final op = Codec.rxOpcode(frame);
    final pl = Codec.rxPayload(frame);
    switch (op) {
      case OpA.setTime:
        capabilities = DeviceCapabilities.fromSetTime(pl);
        notifyListeners();
      case OpA.todaySport:
        // 3-byte big-endian groups: steps, running, calories, distance, duration.
        if (pl.length >= 12) {
          todaySteps = Codec.readU24be(pl, 0);
          todayCalories = Codec.readU24be(pl, 6);
          todayDistanceMeters = Codec.readU24be(pl, 9);
          notifyListeners();
        }
      case OpA.battery:
        // BatteryRsp: [0]=percent, [1]=charging flag.
        if (pl.isNotEmpty && pl[0] <= 100) {
          batteryPercent = pl[0];
          charging = pl.length > 1 && pl[1] != 0;
          notifyListeners();
        }
      case OpA.realTimeHeartRate:
        // pl[0] = instantaneous bpm. Log every frame (even out-of-range) so
        // a firmware that pushes 0x00/0xFF during sensor warm-up is
        // diagnosable from the log alone.
        AppLog.instance.debug(
          'hr',
          '0x1e raw=0x${(pl.isNotEmpty ? pl[0] : -1) & 0xFF} '
              'parsed=${HrParser.parseRealtime(pl)}',
        );
        final bpm = HrParser.parseRealtime(pl);
        if (bpm != null) {
          lastHeartRate = bpm;
          notifyListeners();
        }
      case OpA.startMeasure:
        // StartHeartRateRsp: [0]=type, [1]=errCode, [2]=value. Log every
        // reply (incl. err != 0) so a "session failed" doesn't look like
        // silence — only update lastHeartRate on err==0 with a plausible bpm.
        final r = HrParser.parseStartMeasureReply(pl);
        AppLog.instance.debug(
          'hr',
          '0x69 reply type=${r?.type ?? -1} err=${r?.err ?? -1} '
              'bpm=${r?.bpm ?? '-'}',
        );
        if (r?.bpm != null) {
          lastHeartRate = r!.bpm;
          notifyListeners();
        }
      case OpA.deviceNotify:
      case OpA.deviceSportNotify:
        // 0x73/0x78 carry `dataType + loadData`. Some firmwares push live
        // HR on these opcodes when the canonical 0x1e path is unsupported —
        // try the parser, then log the raw bytes for diagnostics either way.
        final notifyBpm = HrParser.parseDeviceNotify(pl);
        if (notifyBpm != null) {
          AppLog.instance.debug(
            'hr',
            '0x${op.toRadixString(16)} hr=$notifyBpm',
          );
          lastHeartRate = notifyBpm;
          notifyListeners();
        }
        AppLog.instance.debug(
          'rx',
          'Notify op=0x${op.toRadixString(16)} dataType=${pl.isNotEmpty ? pl[0] : -1} '
              'bytes=${AppLog.toHex(pl)}',
        );
    }
  }

  // --- Actions ---

  Future<void> syncTime() => _transport.sendA(Commands.setTime(DateTime.now()));

  Future<void> findDevice() => _transport.sendA(Commands.findDevice());

  Future<void> refreshSteps() => _transport.sendA(Commands.readTodaySport());

  Future<void> refreshBattery() => _transport.sendA(Commands.readBattery());

  /// Waits until the [BleTransport] has received a frame for each opcode in
  /// [opcodes], or [timeout] elapses. Used during the handshake to avoid
  /// declaring "ready" before the initial replies have been parsed.
  Future<void> _waitForReplies(Duration timeout, Set<int> opcodes) async {
    final remaining = {...opcodes};
    final completer = Completer<void>();
    late StreamSubscription<Uint8List> sub;
    sub = _transport.inboundA.listen((frame) {
      if (frame.length != 16) return;
      final op = Codec.rxOpcode(frame);
      if (remaining.remove(op) && remaining.isEmpty) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      AppLog.instance.warn(
        'watch',
        'Handshake: missing replies for opcodes ${remaining.map((o) => "0x${o.toRadixString(16)}").toList()}',
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<void> setBrightness(int level) =>
      _transport.sendA(Commands.setBrightness(level));

  /// Start a heart-rate measurement.
  ///
  /// Sends both the explicit session start (`0x69` type=heartRate=1) AND the
  /// realtime toggle (`0x1e` type=realtimeHeartRate=6). Different firmware
  /// variants honor one or the other — sending both means the device picks
  /// whichever path it actually implements. Replies from either path feed
  /// into `_onFrame` and update `lastHeartRate`.
  Future<void> startHeartRate() async {
    AppLog.instance.info('hr', 'Starting HR (0x69 session + 0x1e realtime)');
    await _transport.sendA(Commands.startMeasure(MeasureType.heartRate));
    await _transport.sendA(
      Commands.startContinuousHr(MeasureType.realtimeHeartRate),
    );
  }

  /// Stop every HR measurement path that [startHeartRate] may have started.
  Future<void> stopHeartRate() async {
    AppLog.instance.info('hr', 'Stopping HR (0x6a session + 0x1e stop)');
    await _transport.sendA(Commands.stopMeasure(MeasureType.heartRate));
    await _transport.sendA(Commands.stopContinuousHr());
  }

  Future<void> enableNotifications(String phoneModel) async {
    await _transport.sendA(Commands.bindAncs(phoneModel));
    await _transport.sendA(Commands.enableAncs());
    _hub.enableAncs(name: 'phone:$phoneModel');
  }

  Future<void> factoryReset() async {
    // Per GHIDRA_DECOMPILATION.md §3.8 (FUN_0082cde8), the firmware does
    // NOT queue a response frame — the BLE re-init tears down the link
    // before any reply could be parsed. Treat the send completing
    // without error as the implicit ack.
    await _transport.sendA(Commands.factoryReset());
    // Inject the event into the dispatcher's controller — guarded by a
    // reflection-free accessor on ProtocolHub so we don't expose the
    // StreamController itself.
    _hub.notifyFactoryResetAccepted();
  }

  /// Direct accessor for the underlying typed-streams hub. Exposed so a
  /// diagnostic UI can observe everything the firmware emits without having
  /// to re-subscribe to the transport.
  ProtocolHub get hub => _hub;

  void _onAncsEvent(Object e) {
    AppLog.instance.debug('watch', 'ancs event: ${e.runtimeType}');
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    _batteryTimer?.cancel();
    _transport.state.removeListener(_onLinkState);
    unawaited(_inboundSub?.cancel());
    _hub.dispose();
    super.dispose();
  }
}
