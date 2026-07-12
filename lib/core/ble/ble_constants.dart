import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// The GATT protocol selected from the discovered service layout.
///
/// Fitbit Air's private characteristics are deliberately not modelled here:
/// the supplied capture establishes only its service layout and standard Heart
/// Rate service, not an authenticated command protocol.
enum WatchProfile { oudmon, fitbitAir }

/// BLE GATT identifiers for the Oudmon smartwatch protocol.
///
/// The watch exposes **two independent logical channels** on one connection
/// (see `PROTOCOL.md` §2):
///
/// * **Channel A** — command channel. Fixed 16-byte frames, write-with-response.
///   Carries every settings/health/notification command.
/// * **Channel B** — large-data/file/OTA channel. `0xBC`-magic length-prefixed
///   frames, write-without-response, sliced into MTU-sized chunks. Carries OTA,
///   H59 file-table operations, sleep/activity data, and alarms. APK-era
///   custom watch-face upload is not implemented by H59MA v14.
class BleUuids {
  BleUuids._();

  // --- Channel A: commands ---
  static final Guid serviceA = Guid('6e40fff0-b5a3-f393-e0a9-e50e24dcca9e');
  static final Guid writeA = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final Guid notifyA = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  // --- Channel B: large data / file / OTA ---
  static final Guid serviceB = Guid('de5bf728-d711-4e47-af26-65e3012a5dc7');
  static final Guid writeB = Guid('de5bf72a-d711-4e47-af26-65e3012a5dc7');
  static final Guid notifyB = Guid('de5bf729-d711-4e47-af26-65e3012a5dc7');

  // --- Standard Device Information service (read during handshake) ---
  static final Guid deviceInfo = Guid('0000180a-0000-1000-8000-00805f9b34fb');
  static final Guid hardwareRevision = Guid(
    '00002a27-0000-1000-8000-00805f9b34fb',
  );
  static final Guid firmwareRevision = Guid(
    '00002a26-0000-1000-8000-00805f9b34fb',
  );

  // Note: `0x2a28` (Software Revision) is NOT a real Device-Info characteristic
  // on this firmware. Per `firmwares/R2_ANALYSIS.md` §7, the bytes that look
  // like `0x2a28` are actually a `0x2803` char-decl + value-UUID `0x2a00`
  // (Device Name, inside the Chinese-vendor `0xfee7` service).

  // --- Vendor "fee7" service (PROTOCOL.md §2.1, R2_ANALYSIS.md §7) ---
  // Present on this OEM's firmware. Currently the app only logs its presence
  // during discovery; no operational characteristic is wired up yet (it is a
  // possible alternate command/OTA surface or Device-Name holder).
  static final Guid serviceFee7 = Guid('0000fee7-0000-1000-8000-00805f9b34fb');
  static final Guid fee7Write = Guid('0000fea1-0000-1000-8000-00805f9b34fb');
  static final Guid fee7Read = Guid('0000fec9-0000-1000-8000-00805f9b34fb');
  static final Guid fee7Notify = Guid('0000fea2-0000-1000-8000-00805f9b34fb');
  static final Guid deviceName = Guid('00002a00-0000-1000-8000-00805f9b34fb');

  // --- Bluetooth SIG Heart Rate service (Fitbit Air read-only support) ---
  static final Guid heartRateService = Guid(
    '0000180d-0000-1000-8000-00805f9b34fb',
  );
  static final Guid heartRateMeasurement = Guid(
    '00002a37-0000-1000-8000-00805f9b34fb',
  );

  // Fitbit Air private GATT surface observed in the supplied capture. This
  // identifies the supported read-only profile without relying on the mutable
  // advertised device name. The characteristic roles below describe only
  // their GATT properties; framing and payload semantics remain unknown.
  static final Guid fitbitAirCommandService = Guid(
    'abbaff00-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirCommandWrite = Guid(
    'abbaff01-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirCommandNotify = Guid(
    'abbaff02-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirDataService = Guid(
    'abbafd00-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirDataNotify1 = Guid(
    'abbafd01-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirDataNotify2 = Guid(
    'abbafd02-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirDataRead = Guid(
    'abbafd03-e56a-484c-b832-8b17cf6cbfe8',
  );
  static final Guid fitbitAirControlService = Guid(
    'ac2f0045-8182-4be5-91e0-2992e6b40ebb',
  );
  static final Guid fitbitAirControlRead = Guid(
    'ac2f0145-8182-4be5-91e0-2992e6b40ebb',
  );
  static final Guid fitbitAirControlWrite = Guid(
    'ac2f2845-8182-4be5-91e0-2992e6b40ebb',
  );
  static final Guid fitbitAirTelemetryService = Guid(
    '4eee1c00-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryNotify1 = Guid(
    '4eee1c01-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryWrite = Guid(
    '4eee1c02-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryRead = Guid(
    '4eee1c03-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryIndicate = Guid(
    '4eee1c04-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryNotify2 = Guid(
    '4eee1c05-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryReadWriteNotify = Guid(
    '4eee1c06-4133-479b-8663-02c84bdc14be',
  );
  static final Guid fitbitAirTelemetryReadWriteIndicate = Guid(
    '4eee1c07-4133-479b-8663-02c84bdc14be',
  );

  static bool isFitbitAirPrivateService(Guid uuid) =>
      uuid == fitbitAirCommandService ||
      uuid == fitbitAirDataService ||
      uuid == fitbitAirControlService ||
      uuid == fitbitAirTelemetryService;

  /// Default Channel-B chunk size before PackageLength (`0x2f`) negotiation.
  static const int defaultPackageLength = 20;

  /// Channel-A frames are always exactly this many bytes.
  static const int channelAFrameLength = 16;

  /// Name prefixes advertised by supported watches, used to filter scans.
  /// Empty = show every device advertising the command service.
  static const List<String> namePrefixes = <String>[];
}
