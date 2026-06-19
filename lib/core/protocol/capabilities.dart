import 'dart:typed_data';

/// Device capabilities parsed from the two on-wire bitmaps:
/// the [SetTimeRsp] 14-byte manifest (§4.2.1) and the
/// [DeviceSupportFunctionRsp] bitmap (§4.2.2).
///
/// Only the flags the app actually gates on are surfaced; the raw payloads are
/// retained so screens can probe additional bits without a code change.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.screenWidth = 0,
    this.screenHeight = 0,
    this.maxWatchFaces = 0,
    this.maxContacts = 0,
    this.heart = false,
    this.sleep = false,
    this.bloodOxygen = false,
    this.bloodPressure = false,
    this.weather = false,
    this.temperature = false,
    this.menstruation = false,
    this.hrv = false,
    this.stress = false,
    this.ultraviolet = false,
    this.bloodSugar = false,
    this.alarm = false,
    this.dnd = false,
    this.muslim = false,
    this.customWallpaper = false,
    this.takePhoto = true,
  });

  final int screenWidth;
  final int screenHeight;
  final int maxWatchFaces;
  final int maxContacts;

  final bool heart;
  final bool sleep;
  final bool bloodOxygen;
  final bool bloodPressure;
  final bool weather;
  final bool temperature;
  final bool menstruation;
  final bool hrv;
  final bool stress;
  final bool ultraviolet;
  final bool bloodSugar;
  final bool alarm;
  final bool dnd;
  final bool muslim;
  final bool customWallpaper;
  final bool takePhoto;

  static bool _bit(int v, int b) => (v & (1 << b)) != 0;

  /// Parses the 14-byte `SetTimeRsp` capability manifest (payload-relative).
  factory DeviceCapabilities.fromSetTime(Uint8List pl) {
    if (pl.length < 14) return const DeviceCapabilities();
    final contactsByte = pl[0x0c];
    return DeviceCapabilities(
      temperature: pl[0] == 1,
      heart: _bit(pl[1], 6),
      sleep: _bit(pl[1], 7),
      menstruation: _bit(pl[2], 0),
      customWallpaper: _bit(pl[3], 0),
      bloodOxygen: _bit(pl[3], 1),
      bloodPressure: _bit(pl[3], 2),
      weather: _bit(pl[3], 5),
      screenWidth: pl[4] | (pl[5] << 8),
      screenHeight: pl[6] | (pl[7] << 8),
      maxWatchFaces: pl[9],
      maxContacts: contactsByte == 0 ? 20 : contactsByte * 8,
      stress: _bit(pl[0x0d], 4),
      hrv: _bit(pl[0x0d], 5),
    );
  }

  /// Merges in the flags from `DeviceSupportFunctionRsp` (payload-relative).
  DeviceCapabilities mergeSupport(Uint8List pl) {
    if (pl.length < 9) return this;
    return DeviceCapabilities(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      maxWatchFaces: maxWatchFaces,
      maxContacts: maxContacts,
      heart: heart,
      sleep: sleep,
      bloodOxygen: bloodOxygen,
      bloodPressure: bloodPressure,
      weather: weather,
      temperature: temperature || (pl.length > 0x0a && _bit(pl[0x0a], 1)),
      menstruation: menstruation,
      hrv: hrv,
      stress: stress || _bit(pl[7], 0) == false && stress,
      ultraviolet: _bit(pl[7], 0),
      bloodSugar: bloodSugar,
      alarm: _bit(pl[6], 6),
      dnd: _bit(pl[6], 7),
      muslim: _bit(pl[1], 1) || _bit(pl[5], 7),
      customWallpaper: customWallpaper,
      takePhoto: !_bit(pl[6], 2),
    );
  }
}
