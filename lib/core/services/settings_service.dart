import 'package:shared_preferences/shared_preferences.dart';

/// Cloud region for the optional QC Wireless backend.
enum CloudRegion {
  international('https://api1.qcwxkjvip.com/qcwx/'),
  china('https://china.qcwxwire.com/qcwx/');

  const CloudRegion(this.baseUrl);
  final String baseUrl;
}

/// User-controllable app settings.
///
/// **OpenWatch is offline-first.** Nothing leaves the device unless the user
/// explicitly opts in. [cloudSyncEnabled] gates *all* background cloud traffic
/// (health upload/download, social, AI). Firmware lookup is a separate, always
/// explicit, on-demand action — it is never triggered automatically.
class AppSettings {
  const AppSettings({
    this.cloudSyncEnabled = false,
    this.region = CloudRegion.international,
    this.authToken,
    this.autoSyncTimeOnConnect = true,
    this.autoSyncHistoryOnConnect = true,
    this.hrAutoMeasureEnabled = true,
    this.hrIntervalMinutes = 5,
    this.hrLowAlarm = 50,
    this.hrHighAlarm = 120,
    this.stressAutoMeasureEnabled = true,
  });

  /// Master switch for the cloud integration. Default: OFF (offline-first).
  final bool cloudSyncEnabled;

  /// Which backend region to use when cloud is enabled.
  final CloudRegion region;

  /// Bearer-equivalent `token` header value, set after login. Null = anonymous.
  final String? authToken;

  /// Sync the watch clock to phone time right after connecting (local, no cloud).
  final bool autoSyncTimeOnConnect;

  /// Trigger a one-shot incremental history sync each time the BLE link
  /// transitions to `ready`. The sync only re-fetches days the watch
  /// says have new data AND we don't already have on disk — no work
  /// happens on days with nothing new.
  final bool autoSyncHistoryOnConnect;

  // --- Wristband sensor settings ---

  /// Enable automatic heart-rate measurement. Default: true.
  final bool hrAutoMeasureEnabled;

  /// Interval between automatic HR readings, in minutes (1..60). Default: 5.
  final int hrIntervalMinutes;

  /// Low HR alarm threshold, BPM (0 = disabled). Default: 50.
  final int hrLowAlarm;

  /// High HR alarm threshold, BPM (0 = disabled). Default: 120.
  final int hrHighAlarm;

  /// Enable automatic stress (pressure) measurement. Default: true.
  /// Pushed to the watch on connect via `0x38`.
  final bool stressAutoMeasureEnabled;

  AppSettings copyWith({
    bool? cloudSyncEnabled,
    CloudRegion? region,
    String? authToken,
    bool? autoSyncTimeOnConnect,
    bool? autoSyncHistoryOnConnect,
    bool? hrAutoMeasureEnabled,
    int? hrIntervalMinutes,
    int? hrLowAlarm,
    int? hrHighAlarm,
    bool? stressAutoMeasureEnabled,
  }) => AppSettings(
    cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
    region: region ?? this.region,
    authToken: authToken ?? this.authToken,
    autoSyncTimeOnConnect: autoSyncTimeOnConnect ?? this.autoSyncTimeOnConnect,
    autoSyncHistoryOnConnect:
        autoSyncHistoryOnConnect ?? this.autoSyncHistoryOnConnect,
    hrAutoMeasureEnabled: hrAutoMeasureEnabled ?? this.hrAutoMeasureEnabled,
    hrIntervalMinutes: hrIntervalMinutes ?? this.hrIntervalMinutes,
    hrLowAlarm: hrLowAlarm ?? this.hrLowAlarm,
    hrHighAlarm: hrHighAlarm ?? this.hrHighAlarm,
    stressAutoMeasureEnabled:
        stressAutoMeasureEnabled ?? this.stressAutoMeasureEnabled,
  );
}

/// Persists [AppSettings] in `SharedPreferences`.
class SettingsService {
  SettingsService(this._prefs);
  final SharedPreferences _prefs;

  static const _kCloud = 'cloud_sync_enabled';
  static const _kRegion = 'cloud_region';
  static const _kToken = 'auth_token';
  static const _kAutoTime = 'auto_sync_time';
  static const _kAutoHistory = 'auto_sync_history';
  static const _kLastDeviceId = 'last_device_id';
  static const _kLastDeviceName = 'last_device_name';
  static const _kHrEnabled = 'hr_auto_measure_enabled';
  static const _kHrInterval = 'hr_interval_minutes';
  static const _kHrLow = 'hr_low_alarm';
  static const _kHrHigh = 'hr_high_alarm';
  static const _kStressEnabled = 'stress_auto_measure_enabled';

  static Future<SettingsService> create() async =>
      SettingsService(await SharedPreferences.getInstance());

  // --- Paired device (for auto-reconnect on launch) ---

  String? get lastDeviceId => _prefs.getString(_kLastDeviceId);
  String? get lastDeviceName => _prefs.getString(_kLastDeviceName);

  Future<void> saveLastDevice(String id, String name) async {
    await _prefs.setString(_kLastDeviceId, id);
    await _prefs.setString(_kLastDeviceName, name);
  }

  Future<void> clearLastDevice() async {
    await _prefs.remove(_kLastDeviceId);
    await _prefs.remove(_kLastDeviceName);
  }

  AppSettings load() => AppSettings(
    cloudSyncEnabled: _prefs.getBool(_kCloud) ?? false,
    region: CloudRegion.values[_prefs.getInt(_kRegion) ?? 0],
    authToken: _prefs.getString(_kToken),
    autoSyncTimeOnConnect: _prefs.getBool(_kAutoTime) ?? true,
    autoSyncHistoryOnConnect: _prefs.getBool(_kAutoHistory) ?? true,
    hrAutoMeasureEnabled: _prefs.getBool(_kHrEnabled) ?? true,
    hrIntervalMinutes: _prefs.getInt(_kHrInterval) ?? 5,
    hrLowAlarm: _prefs.getInt(_kHrLow) ?? 50,
    hrHighAlarm: _prefs.getInt(_kHrHigh) ?? 120,
    stressAutoMeasureEnabled: _prefs.getBool(_kStressEnabled) ?? true,
  );

  Future<void> save(AppSettings s) async {
    await _prefs.setBool(_kCloud, s.cloudSyncEnabled);
    await _prefs.setInt(_kRegion, s.region.index);
    await _prefs.setBool(_kAutoTime, s.autoSyncTimeOnConnect);
    await _prefs.setBool(_kAutoHistory, s.autoSyncHistoryOnConnect);
    await _prefs.setBool(_kHrEnabled, s.hrAutoMeasureEnabled);
    await _prefs.setInt(_kHrInterval, s.hrIntervalMinutes);
    await _prefs.setInt(_kHrLow, s.hrLowAlarm);
    await _prefs.setInt(_kHrHigh, s.hrHighAlarm);
    await _prefs.setBool(_kStressEnabled, s.stressAutoMeasureEnabled);
    if (s.authToken != null) {
      await _prefs.setString(_kToken, s.authToken!);
    } else {
      await _prefs.remove(_kToken);
    }
  }
}
