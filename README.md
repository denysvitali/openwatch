# OpenWatch

Open-source, **offline-first** companion app to manage Oudmon-based BLE
smartwatches — a clean-room Flutter rewrite of the proprietary
`com.qcwireless.qcwatch` ("QWatch Pro") app.

The BLE protocol was reverse-engineered by static analysis of the shipped APK.
The full spec lives in [`PROTOCOL.md`](PROTOCOL.md).

## Principles

- **Offline-first.** Nothing leaves your device by default. The cloud
  integration (health sync, watch-face market, firmware lookup) is **off** until
  you explicitly enable it in Settings.
- **Local firmware.** You can fetch the latest firmware once (explicit action)
  and store it on the filesystem; flashing then works fully offline over BLE.
- **No vendor lock-in.** Everything talks directly to the watch over GATT.

## Architecture

```
lib/
  core/
    ble/         BLE transport (flutter_blue_plus): two-channel GATT, write queue
    protocol/    Pure codec — frame builders/parsers, opcodes, capabilities, DFU
    services/    SettingsService, WatchManager, CloudApi (opt-in), FirmwareService
    providers/   Riverpod wiring
    routing/     go_router shell
  features/      One folder per screen (scan, dashboard, health, alerts, settings, firmware)
```

### The watch protocol in one paragraph

Two logical GATT channels on one connection. **Channel A** (`6e40fff0`) carries
fixed 16-byte commands with an additive 8-bit checksum, write-with-response,
opcode-correlated responses, gated behind a handshake (read FW/HW revision →
ready). **Channel B** (`de5bf728`) carries `0xBC`-magic, length-prefixed,
CRC16-protected large data sliced into MTU chunks — used for OTA, H59
file-table operations, sleep/activity data, and alarms. APK-era watch-face
upload is documented as unsupported on H59MA v14. See `PROTOCOL.md` for every
opcode.

## Development

This repo uses [mise](https://mise.jdx.dev/) to pin Flutter. With mise
activated, `flutter` and `dart` are available automatically when you `cd` into
the repo.

```bash
mise install                              # install the pinned Flutter SDK
flutter pub get
flutter analyze
dart format --output=none --set-exit-if-changed .
flutter test
```

## Status

Working: device scan/connect, handshake, time sync, capability detection,
find-device, today's steps/calories, live heart-rate, notification enable,
factory reset, offline-first cloud toggle, local history sync UI, firmware
fetch-and-store + OTA flow. APK-era Channel-B custom watch-face upload is
documented as unsupported on H59MA v14 (`0x3a` returns compact NAK code `0`).

Open verification gaps (flagged in `PROTOCOL.md` §8.5): ECG/PPG notify
opcodes, BP compact-byte-to-cuff correlation, and the exact
`@RequiresSignature` cloud endpoint set. Channel B CRC is resolved as
CRC-16/MODBUS from firmware. Legacy APK-layer bind (`0x10`) is documented as
not implemented on H59MA Channel-A; OpenWatch uses Channel-A `0x04` bind.

## Legal

OpenWatch is an independent, interoperability-focused project. It ships no code
from the original app and is not affiliated with QC Wireless or Oudmon.
