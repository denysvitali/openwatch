import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../protocol/capabilities.dart';
import '../protocol/codec.dart';
import '../protocol/commands.dart';
import '../protocol/opcodes.dart';
import 'app_log.dart';

/// High-level device manager: runs the post-connect handshake (time sync +
/// capability probe), keeps live device state, and exposes management actions.
///
/// Sits on top of [BleTransport] and is fully local — no cloud involvement.
class WatchManager extends ChangeNotifier {
  WatchManager(this._transport, {this.autoSyncTime = true}) {
    _transport.state.addListener(_onLinkState);
    _inboundSub = _transport.inboundA.listen(_onFrame);
    _onLinkState();
  }

  final BleTransport _transport;
  bool autoSyncTime;
  StreamSubscription<Uint8List>? _inboundSub;
  LinkState _last = LinkState.disconnected;
  bool _handshaking = false;

  DeviceCapabilities capabilities = const DeviceCapabilities();
  int? batteryPercent;
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
    }
    _last = s;
    notifyListeners();
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
      await refreshSteps();
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
      case OpA.deviceNotify:
        // 0x73 carries dataType + loadData; battery is a likely dataType.
        // Best-effort: a single-byte percentage payload. Verify on live capture.
        if (pl.length >= 2 && pl[1] <= 100) {
          batteryPercent = pl[1];
          notifyListeners();
        }
      case OpA.realTimeHeartRate:
        if (pl.isNotEmpty && pl[0] > 0) {
          lastHeartRate = pl[0];
          notifyListeners();
        }
      case OpA.startMeasure:
        // [0]=type, [1]=errCode, [2]=value. A non-zero value for the HR types
        // is a live bpm sample; value 0 means "still measuring".
        if (pl.length >= 3 && pl[2] > 0) {
          lastHeartRate = pl[2];
          notifyListeners();
        }
    }
  }

  // --- Actions ---

  Future<void> syncTime() => _transport.sendA(Commands.setTime(DateTime.now()));

  Future<void> findDevice() => _transport.sendA(Commands.findDevice());

  Future<void> refreshSteps() => _transport.sendA(Commands.readTodaySport());

  Future<void> setBrightness(int level) =>
      _transport.sendA(Commands.setBrightness(level));

  Future<void> startHeartRate() =>
      _transport.sendA(Commands.startMeasure(MeasureType.realtimeHeartRate));

  Future<void> stopHeartRate() =>
      _transport.sendA(Commands.stopMeasure(MeasureType.realtimeHeartRate));

  Future<void> enableNotifications(String phoneModel) async {
    await _transport.sendA(Commands.bindAncs(phoneModel));
    await _transport.sendA(Commands.enableAncs());
  }

  Future<void> factoryReset() => _transport.sendA(Commands.factoryReset());

  @override
  void dispose() {
    _transport.state.removeListener(_onLinkState);
    unawaited(_inboundSub?.cancel());
    super.dispose();
  }
}
