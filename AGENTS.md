# AGENTS.md

## Project

OpenWatch is a clean-room Flutter companion app for Oudmon-based BLE
smartwatches. Preserve the core product constraints:

- Offline-first: nothing leaves the device unless the user explicitly enables
  cloud integration in Settings.
- Local firmware: firmware fetch is explicit; flashing must work from local
  files over BLE.
- No vendor lock-in: communicate directly with the watch over GATT.

Read `PROTOCOL.md` before changing protocol bytes, opcodes, payload layouts, or
CRC/checksum behavior. Treat undocumented protocol values as "needs live
capture" rather than inventing fields.

## Architecture

- `lib/main.dart` initializes Android user certificates, OpenTelemetry, and the
  Riverpod app.
- `lib/core/ble/` owns GATT connection lifecycle and serialized writes.
- `lib/core/protocol/` is pure, synchronous protocol code. Keep it free of BLE
  side effects and easy to unit test.
- `lib/core/services/` contains high-level app services such as
  `WatchManager`, `HistorySync`, `HistoryStore`, firmware, cloud, logging, and
  OpenTelemetry.
- `lib/core/providers/app_providers.dart` contains Riverpod wiring.
- `lib/core/routing/app_router.dart` owns `go_router` routes.
- `lib/features/` contains screen-level UI by feature.

Important provider constraint: do not `watch(settingsProvider)` inside
`watchManagerProvider`; use `ref.read` plus `ref.listen` so preferences
hydration does not recreate the `WatchManager` or duplicate the handshake.

## Development

Prefer the repo's declared Flutter environment:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

The README notes that Nix users should use the `sdk-links` Flutter wrapper
rather than a plain wrapper that writes into the Nix store. On a non-Nix host,
Flutter `>=3.38.0` and Dart `>=3.10.0` are expected.

For code generation:

```bash
dart run build_runner build --delete-conflicting-outputs
```

## Testing

Use the narrowest relevant test first, then broaden:

- Protocol or parser changes: add/update focused tests under `test/`.
- UI changes: run `flutter analyze` and at least the relevant widget test.
- Cross-cutting changes: run the full `flutter test` suite.

CI runs `flutter pub get`, format check, `flutter analyze`, and
`flutter test`. Release APK builds depend on those checks.

## Protocol And BLE Rules

- Channel A frames are fixed 16-byte command frames with an additive checksum.
  The top bit is the Channel A error flag.
- Channel B uses `0xBC` magic, length-prefixed payloads, CRC16, and MTU-sliced
  chunks for larger transfers.
- `0xFEE7` is a separate optional command path; do not apply Channel A opcode
  masking rules to it.
- Keep protocol code deterministic and testable. Side effects belong in
  services such as `WatchManager` or `HistorySync`.

## Cloud And Privacy

`cloudApiProvider` must return `null` unless the user enabled cloud sync. Every
cloud call site must null-check. Do not add telemetry, networking, uploads, or
vendor API calls that bypass the offline-first setting.

## Observability

Use `OpenTelemetryService().startTrace(...)` for new spans. It can return
`null` before initialization, so callers must tolerate that. Long-lived
listeners should push/pop the current span around callback work so child spans
parent correctly.

## UI

Keep Flutter UI changes consistent with the app's existing Material 3 +
Cupertino-icon style. Prefer polished, dense app screens over marketing-style
layouts. Keep screen code inside the relevant `lib/features/<feature>/`
directory unless a reusable widget is clearly shared.

## Git Hygiene

The worktree may contain unrelated user changes. Check `git status --short`
before editing and before finishing. Do not stage, revert, or overwrite
unrelated changes. Keep commits focused and use the existing conventional commit
style, such as `fix(history): ...` or `feat(ui): ...`.
