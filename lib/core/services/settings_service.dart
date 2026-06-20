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
  });

  /// Master switch for the cloud integration. Default: OFF (offline-first).
  final bool cloudSyncEnabled;

  /// Which backend region to use when cloud is enabled.
  final CloudRegion region;

  /// Bearer-equivalent `token` header value, set after login. Null = anonymous.
  final String? authToken;

  /// Sync the watch clock to phone time right after connecting (local, no cloud).
  final bool autoSyncTimeOnConnect;

  AppSettings copyWith({
    bool? cloudSyncEnabled,
    CloudRegion? region,
    String? authToken,
    bool? autoSyncTimeOnConnect,
  }) =>
      AppSettings(
        cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
        region: region ?? this.region,
        authToken: authToken ?? this.authToken,
        autoSyncTimeOnConnect:
            autoSyncTimeOnConnect ?? this.autoSyncTimeOnConnect,
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
  static const _kLastDeviceId = 'last_device_id';
  static const _kLastDeviceName = 'last_device_name';

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
      );

  Future<void> save(AppSettings s) async {
    await _prefs.setBool(_kCloud, s.cloudSyncEnabled);
    await _prefs.setInt(_kRegion, s.region.index);
    await _prefs.setBool(_kAutoTime, s.autoSyncTimeOnConnect);
    if (s.authToken != null) {
      await _prefs.setString(_kToken, s.authToken!);
    } else {
      await _prefs.remove(_kToken);
    }
  }
}
