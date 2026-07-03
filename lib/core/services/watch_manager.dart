import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart'
    show SpanKind;

import '../ble/ble_transport.dart';
import '../protocol/capabilities.dart';
import '../protocol/channel_a.dart';
import '../protocol/codec.dart';
import '../protocol/commands.dart';
import '../protocol/fee7_dispatcher.dart';
import '../protocol/hr_parser.dart';
import '../protocol/opcodes.dart';
import 'app_log.dart';
import 'opentelemetry_service.dart';
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
    // Battery push on the vendor 0xFEE7 channel: H59MA v14 emits a
    // 'a' status response (0x61) whenever the battery state changes,
    // plus a one-shot 'H' handshake (0x48) at link-up that carries the
    // same percent + a charge flag. Both streams are optional — only
    // available when the watch advertises 0xFEE7 — so null-check
    // before subscribing.
    final fee7 = _hub.fee7;
    if (fee7 != null) {
      _fee7StatusSub = fee7.onStatus.listen(_onFee7Status);
      _fee7HandshakeSub = fee7.onHandshake.listen(_onFee7Handshake);
    }
    _onLinkState();
  }

  final WatchLink _transport;
  bool autoSyncTime;
  StreamSubscription<Uint8List>? _inboundSub;
  StreamSubscription<StatusResponse>? _fee7StatusSub;
  StreamSubscription<HandshakeResponse>? _fee7HandshakeSub;
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
  int? lastStress;
  int? lastHrv;
  int? lastBloodPressureSystolic;
  int? lastBloodPressureDiastolic;
  final Set<int> _measuringTypes = {};

  /// DataType ids on 0x73/0x78 known to carry a bpm. Anything outside
  /// this set is forwarded as an opaque notify log so ECG/PPG (and
  /// future sensor additions) cannot silently corrupt [lastHeartRate].
  /// Pinned to the H59MA-class ids observed in live capture — expand
  /// when a new id is verified.
  static const Set<int> _hrNotifyDataTypes = {0x05, 0x06, 0x12};

  /// dataType ids seen on 0x73/0x78 that we did NOT recognise as
  /// HR-class. Surfaced for diagnostics — a future ECG/PPG capture
  /// will land here until the right decoder lands.
  final Set<int> _observedUnknownNotifyTypes = {};
  Uint8List? _lastUnknownNotifyPayload;
  Set<int> get observedUnknownNotifyTypes =>
      Set.unmodifiable(_observedUnknownNotifyTypes);
  Uint8List? get lastUnknownNotifyPayload => _lastUnknownNotifyPayload;
  String? lastMeasurementError;
  bool initialized = false;

  String get hardwareRevision => _transport.hardwareRevision;
  String get firmwareRevision => _transport.firmwareRevision;
  bool get isReady => _transport.isReady;
  bool get measuringHeartRate =>
      _measuringTypes.contains(MeasureType.heartRate.id);
  bool get measuringBloodPressure =>
      _measuringTypes.contains(MeasureType.bloodPressure.id);
  bool get measuringStress => _measuringTypes.contains(MeasureType.pressure.id);
  bool get measuringHrv => _measuringTypes.contains(MeasureType.hrv.id);

  void _onLinkState() {
    final s = _transport.state.value;
    if (s == LinkState.ready && _last != LinkState.ready) {
      unawaited(_runHandshake());
    }
    if (s == LinkState.disconnected) {
      initialized = false;
      _handshaking = false;
      _measuringTypes.clear();
      lastMeasurementError = null;
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
    // Top-level span for the post-connect handshake — the BLE link
    // is treated as a client span because we're the initiator.
    final span = OpenTelemetryService().startTrace(
      'watch.handshake',
      kind: SpanKind.client,
      attributes: {
        'watch.auto_sync_time': autoSyncTime,
        'watch.capabilities.hr': false,
        'watch.capabilities.spo2': false,
        'watch.capabilities.bp': false,
        'watch.capabilities.sleep': false,
        'watch.capabilities.alarm': false,
      },
    );
    try {
      if (autoSyncTime) {
        await _transport.sendA(Commands.setTime(DateTime.now()));
      }
      final support = await _transport.requestA(Commands.deviceSupport());
      capabilities = capabilities.mergeSupport(Codec.rxPayload(support));
      span?.setAttribute('watch.capabilities.hr', capabilities.heart);
      span?.setAttribute('watch.capabilities.spo2', capabilities.bloodOxygen);
      span?.setAttribute('watch.capabilities.bp', capabilities.bloodPressure);
      span?.setAttribute('watch.capabilities.sleep', capabilities.sleep);
      span?.setAttribute('watch.capabilities.alarm', capabilities.alarm);
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
      span?.end();
    } catch (e, st) {
      AppLog.instance.error('watch', 'Handshake failed: $e');
      span?.recordError(e, st);
      span?.end(ok: false);
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
        final totals = SportTotals.tryParse(pl);
        if (totals != null) {
          todaySteps = totals.steps;
          todayCalories = totals.calories;
          todayDistanceMeters = totals.distanceMeters;
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
              'value=${r?.value ?? '-'} bpm=${r?.bpm ?? '-'} '
              'bp=${r?.systolic ?? '-'}/${r?.diastolic ?? '-'}',
        );
        if (r != null) _handleMeasureReply(r);
      case OpA.stopMeasure:
        final r = HrParser.parseStartMeasureReply(pl);
        if (r != null) _handleMeasureReply(r, fromStop: true);
      case OpA.deviceNotify:
      case OpA.deviceSportNotify:
        // 0x73/0x78 carry `dataType + loadData`. The dataType byte at
        // pl[0] discriminates which sensor is producing the frame:
        //   * HR-class ids (e.g. 0x05/0x06/0x12 on H59MA) carry a bpm.
        //   * ECG/PPG/blood-oxygen/etc. share these opcodes but have
        //     a different payload shape — see PROTOCOL.md §4.3 TODO
        //     on `HealthEcgRsp` / `PpgDataRspCmd`.
        //
        // HrParser.parseDeviceNotify deliberately probes pl[1..4] for
        // any plausible bpm; without a dataType gate that probe
        // would silently mis-classify an ECG/PPG frame as HR when a
        // byte in 30..240 happens to fall at one of those offsets.
        // Gate on the dataType here so only HR-class ids update
        // [lastHeartRate]; everything else is surfaced as an opaque
        // log so the next live capture can index unknown dataTypes.
        final dataType = pl.isEmpty ? null : pl[0] & 0xFF;
        if (dataType != null && _hrNotifyDataTypes.contains(dataType)) {
          final notifyBpm = HrParser.parseDeviceNotify(pl);
          if (notifyBpm != null) {
            AppLog.instance.debug(
              'hr',
              '0x${op.toRadixString(16)} hr=$notifyBpm',
            );
            lastHeartRate = notifyBpm;
            notifyListeners();
          }
        } else {
          // Unknown or non-HR dataType — record so a future live
          // capture of ECG/PPG (PROTOCOL.md §4.3 TODO) can fill in
          // the right decoder without losing data.
          _observedUnknownNotifyTypes.add(dataType ?? -1);
          _lastUnknownNotifyPayload = pl;
        }
        AppLog.instance.debug(
          'rx',
          'Notify op=0x${op.toRadixString(16)} dataType=${dataType ?? -1} '
              'bytes=${AppLog.toHex(pl)}',
        );
    }
  }

  /// `0x61` 'a' status push — battery + step counter. Updates the
  /// shared [batteryPercent] field so the UI reflects the watch's
  /// real-time state without waiting for the 15-minute poll.
  void _onFee7Status(StatusResponse s) {
    final pct = s.battery & 0xFF;
    if (pct <= 100) {
      batteryPercent = pct;
      notifyListeners();
    }
    // Step counter is exposed via `s.stepsLowByte` for diagnostics.
    AppLog.instance.debug(
      'fee7',
      'status battery=$pct stepsLow=0x${s.stepsLowByte.toRadixString(16)}',
    );
  }

  /// `0x48` 'H' handshake — emits once at link-up with hw/fw version,
  /// battery, and charge flags. We only consume the battery here;
  /// hw/fw are surfaced through [hardwareRevision]/[firmwareRevision]
  /// from the transport-level handshake.
  void _onFee7Handshake(HandshakeResponse h) {
    final pct = h.batteryPercent;
    if (pct != null && pct <= 100) {
      batteryPercent = pct;
    }
    // status: low byte = flags, high byte = state. Bit 0 of the low
    // byte is the charge flag per GHIDRA §8.2 — invert our convention
    // so `charging==true` means actively charging.
    if (h.status != null) {
      charging = (h.status! & 0x01) != 0;
    }
    notifyListeners();
    AppLog.instance.debug(
      'fee7',
      'handshake battery=${pct ?? '-'} charging=$charging status=0x'
          '${(h.status ?? 0).toRadixString(16)}',
    );
  }

  void _handleMeasureReply(HrStartMeasureResult r, {bool fromStop = false}) {
    if (r.err != 0) {
      _measuringTypes.remove(r.type);
      lastMeasurementError =
          'Measurement failed (0x${r.err.toRadixString(16)})';
      notifyListeners();
      return;
    }
    var finalValue = false;
    switch (MeasureType.fromId(r.type)) {
      case MeasureType.heartRate:
      case MeasureType.realtimeHeartRate:
        if (r.bpm != null) {
          lastHeartRate = r.bpm;
          finalValue = true;
        }
      case MeasureType.bloodPressure:
        final sbp = r.systolic;
        final dbp = r.diastolic;
        if (sbp != null &&
            dbp != null &&
            sbp >= 60 &&
            sbp <= 250 &&
            dbp >= 30 &&
            dbp <= 150) {
          lastBloodPressureSystolic = sbp;
          lastBloodPressureDiastolic = dbp;
          finalValue = true;
        }
      case MeasureType.pressure:
        if (r.value > 1 && r.value < 100) {
          lastStress = r.value;
          finalValue = true;
        }
      case MeasureType.hrv:
        if (r.value > 1 && r.value < 255) {
          lastHrv = r.value;
          finalValue = true;
        }
      default:
        break;
    }
    if (finalValue) {
      _measuringTypes.remove(r.type);
      lastMeasurementError = null;
    } else if (fromStop) {
      _measuringTypes.remove(r.type);
    } else if (r.value <= 1) {
      _measuringTypes.add(r.type);
    }
    notifyListeners();
  }

  // --- Actions ---

  /// Wrap a single BLE action in a `watch.action.<name>` span so we
  /// can measure fire-and-forget calls and time-to-error consistently.
  Future<T> _withActionSpan<T>(String name, Future<T> Function() body) async {
    final span = OpenTelemetryService().startChildSpan(
      'watch.action.$name',
      attributes: {'watch.action': name},
    );
    try {
      final result = await body();
      span?.end();
      return result;
    } catch (e, st) {
      span?.recordError(e, st);
      span?.end(ok: false);
      rethrow;
    }
  }

  Future<void> syncTime() => _withActionSpan(
    'sync_time',
    () => _transport.sendA(Commands.setTime(DateTime.now())),
  );

  Future<void> findDevice() => _withActionSpan(
    'find_device',
    () => _transport.sendA(Commands.findDevice()),
  );

  Future<void> refreshSteps() => _withActionSpan(
    'refresh_steps',
    () => _transport.sendA(Commands.readTodaySport()),
  );

  Future<void> refreshBattery() => _withActionSpan(
    'refresh_battery',
    () => _transport.sendA(Commands.readBattery()),
  );

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

  /// Apply the user's configured HR auto-measure settings to the watch.
  /// Sends `HeartRateSettingReq` (0x16) with the stored interval and
  /// alarm thresholds. The watch echoes the request frame on success.
  Future<void> applyHeartRateSettings({
    required bool enabled,
    required int interval,
    int tooLow = 50,
    int tooHigh = 120,
  }) => _withActionSpan(
    'apply_hr_settings',
    () => _transport.sendA(
      Commands.setHeartRateSetting(
        enabled: enabled,
        interval: interval,
        tooLow: tooLow,
        tooHigh: tooHigh,
      ),
    ),
  );

  /// Start a heart-rate measurement.
  ///
  /// Sends both the explicit session start (`0x69` type=heartRate=1) AND the
  /// realtime toggle (`0x1e` action=start). Different firmware
  /// variants honor one or the other — sending both means the device picks
  /// whichever path it actually implements. Replies from either path feed
  /// into `_onFrame` and update `lastHeartRate`.
  Future<void> startHeartRate() => _withActionSpan(
    'start_heart_rate',
    () async {
      AppLog.instance.info('hr', 'Starting HR (0x69 session + 0x1e realtime)');
      _markMeasureStarted(MeasureType.heartRate);
      try {
        await _transport.sendA(Commands.startMeasure(MeasureType.heartRate));
        await _transport.sendA(Commands.startContinuousHr());
      } catch (_) {
        _markMeasureStopped(MeasureType.heartRate);
        rethrow;
      }
    },
  );

  /// Stop every HR measurement path that [startHeartRate] may have started.
  Future<void> stopHeartRate() => _withActionSpan('stop_heart_rate', () async {
    AppLog.instance.info('hr', 'Stopping HR (0x6a session + 0x1e stop)');
    try {
      await _transport.sendA(Commands.stopMeasure(MeasureType.heartRate));
      await _transport.sendA(Commands.stopContinuousHr());
    } finally {
      _markMeasureStopped(MeasureType.heartRate);
    }
  });

  Future<void> startBloodPressure() => _withActionSpan(
    'start_blood_pressure',
    () => _startMeasure(MeasureType.bloodPressure),
  );

  Future<void> stopBloodPressure() => _withActionSpan(
    'stop_blood_pressure',
    () => _stopMeasure(MeasureType.bloodPressure),
  );

  Future<void> startStress() => _withActionSpan(
    'start_stress',
    () => _startMeasure(MeasureType.pressure),
  );

  Future<void> stopStress() =>
      _withActionSpan('stop_stress', () => _stopMeasure(MeasureType.pressure));

  Future<void> startHrv() =>
      _withActionSpan('start_hrv', () => _startMeasure(MeasureType.hrv));

  Future<void> stopHrv() =>
      _withActionSpan('stop_hrv', () => _stopMeasure(MeasureType.hrv));

  Future<void> _startMeasure(MeasureType type) async {
    _markMeasureStarted(type);
    try {
      await _transport.sendA(Commands.startMeasure(type));
    } catch (_) {
      _markMeasureStopped(type);
      rethrow;
    }
  }

  Future<void> _stopMeasure(MeasureType type) async {
    try {
      await _transport.sendA(Commands.stopMeasure(type));
    } finally {
      _markMeasureStopped(type);
    }
  }

  void _markMeasureStarted(MeasureType type) {
    _measuringTypes.add(type.id);
    lastMeasurementError = null;
    notifyListeners();
  }

  void _markMeasureStopped(MeasureType type) {
    _measuringTypes.remove(type.id);
    notifyListeners();
  }

  Future<void> enableNotifications(String phoneModel) =>
      _withActionSpan('enable_notifications', () async {
        await _transport.sendA(Commands.bindAncs(phoneModel));
        await _transport.sendA(Commands.enableAncs());
        _hub.enableAncs(name: 'phone:$phoneModel');
      });

  Future<void> factoryReset() => _withActionSpan('factory_reset', () async {
    // Per GHIDRA_DECOMPILATION.md §3.8 (FUN_0082cde8), the firmware does
    // NOT queue a response frame — the BLE re-init tears down the link
    // before any reply could be parsed. Treat the send completing
    // without error as the implicit ack.
    await _transport.sendA(Commands.factoryReset());
    // Inject the event into the dispatcher's controller — guarded by a
    // reflection-free accessor on ProtocolHub so we don't expose the
    // StreamController itself.
    _hub.notifyFactoryResetAccepted();
  });

  // -- Display / theme / wallpaper -----------------------------------------

  Future<void> setTheme(int theme) => _withActionSpan(
    'set_theme',
    () => _transport.sendA(Commands.setTheme(theme)),
  );

  Future<void> setWallpaper(int wallpaper) => _withActionSpan(
    'set_wallpaper',
    () => _transport.sendA(Commands.setWallpaper(wallpaper)),
  );

  Future<void> setDisplayClock({required bool enabled}) => _withActionSpan(
    'set_display_clock',
    () => _transport.sendA(Commands.setDisplayClock(enabled: enabled)),
  );

  Future<void> setTimeFormat({required bool is24, required bool metric}) =>
      _withActionSpan(
        'set_time_format',
        () => _transport.sendA(
          Commands.setTimeFormat(is24: is24, metric: metric),
        ),
      );

  Future<void> setDegreeSwitch({
    required bool enabled,
    required bool isCelsius,
  }) => _withActionSpan(
    'set_degree_switch',
    () => _transport.sendA(
      Commands.setDegreeSwitch(enabled: enabled, isCelsius: isCelsius),
    ),
  );

  // -- DND / targets / sedentary / drink -----------------------------------

  Future<void> setDnd({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
  }) => _withActionSpan(
    'set_dnd',
    () => _transport.sendA(
      Commands.setDnd(
        enabled: enabled,
        startHour: startHour,
        startMinute: startMinute,
        endHour: endHour,
        endMinute: endMinute,
      ),
    ),
  );

  Future<void> setTarget({
    required int steps,
    required int calories,
    required int distanceMeters,
  }) => _withActionSpan(
    'set_target',
    () => _transport.sendA(
      Commands.setTarget(
        steps: steps,
        calories: calories,
        distanceMeters: distanceMeters,
      ),
    ),
  );

  Future<void> setSitLong({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    int weekMask = 0,
    int cycleSeconds = 30,
  }) => _withActionSpan(
    'set_sit_long',
    () => _transport.sendA(
      Commands.setSitLong(
        enabled: enabled,
        startHour: startHour,
        startMinute: startMinute,
        endHour: endHour,
        endMinute: endMinute,
        weekMask: weekMask,
        cycleSeconds: cycleSeconds,
      ),
    ),
  );

  Future<void> setDrinkAlarm({
    required int index,
    required bool enabled,
    required int hour,
    required int minute,
    List<bool> weekdays = const [
      false,
      false,
      false,
      false,
      false,
      false,
      false,
    ],
  }) => _withActionSpan(
    'set_drink_alarm',
    () => _transport.sendA(
      Commands.setDrinkAlarm(
        index: index,
        enabled: enabled,
        hour: hour,
        minute: minute,
        weekdays: weekdays,
      ),
    ),
  );

  // -- Auto-measure settings -----------------------------------------------

  Future<void> setHrvSetting({
    required bool enabled,
    int intervalMinutes = 30,
  }) => _withActionSpan(
    'set_hrv_setting',
    () => _transport.sendA(
      Commands.setHrvSetting(
        enabled: enabled,
        intervalMinutes: intervalMinutes,
      ),
    ),
  );

  Future<void> setPressureSetting({required bool enabled}) => _withActionSpan(
    'set_pressure_setting',
    () => _transport.sendA(Commands.setPressureSetting(enabled: enabled)),
  );

  Future<void> setBloodOxygenSetting({required bool enabled}) =>
      _withActionSpan(
        'set_blood_oxygen_setting',
        () =>
            _transport.sendA(Commands.setBloodOxygenSetting(enabled: enabled)),
      );

  Future<void> setBpSetting({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    int multiple = 1,
  }) => _withActionSpan(
    'set_bp_setting',
    () => _transport.sendA(
      Commands.setBpSetting(
        enabled: enabled,
        startHour: startHour,
        startMinute: startMinute,
        endHour: endHour,
        endMinute: endMinute,
        multiple: multiple,
      ),
    ),
  );

  // -- Channel-B custom watch face -----------------------------------------

  /// Send a DIY watch-face definition to the watch via Channel-B 0x3a.
  ///
  /// Each element is a 6-tuple `(type, x, y, r, g, b)`. The Oudmon SDK
  /// caps the list at 32; [Commands.writeCustomWatchFace] truncates
  /// silently so callers don't have to.
  Future<void> writeCustomWatchFace(
    List<({int type, int x, int y, int r, int g, int b})> elements,
  ) => _withActionSpan(
    'write_custom_watch_face',
    () => _transport.sendB(Commands.writeCustomWatchFace(elements)),
  );

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
    unawaited(_fee7StatusSub?.cancel());
    unawaited(_fee7HandshakeSub?.cancel());
    _hub.dispose();
    super.dispose();
  }
}
