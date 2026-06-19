import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// BLE GATT identifiers for the Oudmon smartwatch protocol.
///
/// The watch exposes **two independent logical channels** on one connection
/// (see `PROTOCOL.md` §2):
///
/// * **Channel A** — command channel. Fixed 16-byte frames, write-with-response.
///   Carries every settings/health/notification command.
/// * **Channel B** — large-data/file/OTA channel. `0xBC`-magic length-prefixed
///   frames, write-without-response, sliced into MTU-sized chunks. Carries
///   watch-face upload, file transfer and firmware (DFU) flashing.
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
  static final Guid softwareRevision = Guid(
    '00002a28-0000-1000-8000-00805f9b34fb',
  );

  /// Default Channel-B chunk size before PackageLength (`0x2f`) negotiation.
  static const int defaultPackageLength = 20;

  /// Channel-A frames are always exactly this many bytes.
  static const int channelAFrameLength = 16;

  /// Name prefixes advertised by supported watches, used to filter scans.
  /// Empty = show every device advertising the command service.
  static const List<String> namePrefixes = <String>[];
}
