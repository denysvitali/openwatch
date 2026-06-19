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
    this.temperatureTwoHundred = false,
    this.aiAnalyze = false,
    this.realTimeHr = false,
    this.reduceFat = false,
    this.hideMessageNotification = false,
    this.avatar = false,
    this.newSleepProtocol = false,
    this.ecard = false,
    this.location = false,
    this.ebook = false,
    this.gps = false,
    this.jieLiMusic = false,
    this.album = false,
    this.musicSupport = false,
    this.bpSetting = false,
    this.fourG = false,
    this.record = false,
    this.wechatPay = false,
    this.watchTheme = false,
    this.wechat = false,
    this.menuWallpaper = false,
  });

  final int screenWidth;
  final int screenHeight;
  final int maxWatchFaces;
  final int maxContacts;

  // §4.2.1 health / display flags
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
  final bool newSleepProtocol;
  final bool avatar;
  final bool wechat;

  // §4.2.1 layout / app flags
  final bool customWallpaper;
  final bool gps;
  final bool jieLiMusic;
  final bool album;
  final bool musicSupport;
  final bool ecard;
  final bool location;
  final bool ebook;
  final bool record;
  final bool bpSetting;
  final bool fourG;

  // §4.2.2 misc / lifestyle flags
  final bool alarm;
  final bool dnd;
  final bool muslim;
  final bool takePhoto;
  final bool temperatureTwoHundred;
  final bool aiAnalyze;
  final bool realTimeHr;
  final bool reduceFat;
  final bool hideMessageNotification;
  final bool wechatPay;
  final bool watchTheme;
  final bool menuWallpaper;

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
      // pl[3] b6 is WeChat but **inverted** in the spec: 0 ⇒ true.
      wechat: pl.length > 3 && !_bit(pl[3], 6),
      avatar: _bit(pl[3], 7),
      screenWidth: pl[4] | (pl[5] << 8),
      screenHeight: pl[6] | (pl[7] << 8),
      newSleepProtocol: pl[8] == 1,
      maxWatchFaces: pl[9],
      gps: _bit(pl[0x0a], 3),
      jieLiMusic: _bit(pl[0x0a], 4),
      album: _bit(pl[0x0a], 2),
      ecard: _bit(pl[0x0b], 1),
      location: _bit(pl[0x0b], 2),
      musicSupport: _bit(pl[0x0b], 4),
      ebook: _bit(pl[0x0b], 6),
      bloodSugar: _bit(pl[0x0b], 7),
      maxContacts: contactsByte == 0 ? 20 : contactsByte * 8,
      record: _bit(pl[0x0d], 0),
      bpSetting: _bit(pl[0x0d], 1),
      fourG: _bit(pl[0x0d], 2),
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
      // §4.2.1 flags: only override when the device actually tells us so.
      heart: heart,
      sleep: sleep,
      bloodOxygen: bloodOxygen,
      bloodPressure: bloodPressure,
      weather: weather,
      menstruation: menstruation,
      hrv: hrv,
      customWallpaper: customWallpaper,
      gps: gps,
      jieLiMusic: jieLiMusic,
      album: album,
      ecard: ecard,
      location: location,
      ebook: ebook,
      bloodSugar: bloodSugar,
      record: record,
      bpSetting: bpSetting,
      fourG: fourG,
      newSleepProtocol: newSleepProtocol,
      avatar: avatar,
      wechat: wechat,
      musicSupport: musicSupport,
      // pl[0xa] b1 ⇒ Temperature200 — set the high-precision variant.
      temperature: temperature || _temperature200Celsius(pl),
      temperatureTwoHundred:
          temperatureTwoHundred || _temperature200Celsius(pl),
      stress: stress || _bit(pl[7], 7),
      ultraviolet: ultraviolet || _bit(pl[7], 0),
      // pl[7] b3 RealTimeHr, b4 RealTimeHrRemind, b5 Friends (untouched).
      realTimeHr: realTimeHr || _bit(pl[7], 3),
      alarm: _bit(pl[6], 6),
      dnd: _bit(pl[6], 7),
      // pl[1] b1 Moslin; pl[5] b7 is the Moslin overwrite — honor either.
      muslim: _bit(pl[1], 1) || _bit(pl[5], 7),
      // pl[6] b2 is *notSupportTakePhoto* — so support is the inverse.
      takePhoto: !_bit(pl[6], 2),
      // pl[3] b7 AiAnalyze.
      aiAnalyze: aiAnalyze || (pl.length > 3 && _bit(pl[3], 7)),
      // pl[8] b3 ReduceFat, b4 hideMessageNotification.
      reduceFat: reduceFat || (pl.length > 8 && _bit(pl[8], 3)),
      hideMessageNotification:
          hideMessageNotification || (pl.length > 8 && _bit(pl[8], 4)),
      // pl[4] b0 MenuWallpaper, b2 WechatPay.
      menuWallpaper:
          menuWallpaper || (pl.length > 4 && _bit(pl[4], 0)),
      wechatPay: wechatPay || (pl.length > 4 && _bit(pl[4], 2)),
      // pl[1] b4 WatchTheme.
      watchTheme: watchTheme || _bit(pl[1], 4),
    );
  }

  static bool _temperature200Celsius(Uint8List pl) =>
      pl.length > 0x0a && _bit(pl[0x0a], 1);
}
