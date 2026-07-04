# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

OpenWatch is a **clean-room Flutter rewrite** of the proprietary `com.qcwireless.qcwatch` ("QWatch Pro") companion app, targeting **Oudmon-based BLE smartwatches** (firmware H59MA v13/v14). The BLE protocol was reverse-engineered by static analysis of the shipped APK and H59MA firmware — the full spec is in `PROTOCOL.md`; the current firmware reference is `firmwares/GHIDRA_DECOMPILATION.md` plus the consolidated byte-level notes in `firmwares/FIRMWARE_ANALYSIS.md`. Treat `firmwares/RE_FIRMWARE.md` and raw `_re/` outputs as older evidence logs unless a newer doc points back to them.

Hard product principles (must be preserved):
- **Offline-first.** Nothing leaves the device until the user explicitly enables cloud sync in Settings.
- **Local firmware.** Firmware images can be fetched once and then flashed entirely over BLE, offline.
- **No vendor lock-in.** Everything speaks to the watch directly over GATT.

## Development commands

The repo uses [mise](https://mise.jdx.dev/) to pin Flutter. With mise activated in your shell, `flutter` and `dart` are available automatically when you `cd` into the repo; otherwise prefix commands with `mise x --`.

```bash
mise install                              # install the pinned Flutter SDK (one-time per machine)
flutter pub get
flutter analyze
dart format --output=none --set-exit-if-changed .
```

**Do not run `flutter test` locally.** Tests are meant to run in CI only; the local Flutter toolchain in this environment is not trusted to produce reliable test results. Use `flutter analyze` and `dart format` for local validation, then push and monitor the GitHub Actions run. The CI workflow runs the full test suite.

Codegen (freezed / json_serializable):

```bash
dart run build_runner build --delete-conflicting-outputs
```

Release build (Android arm64):

```bash
flutter build apk --release --target-platform android-arm64
```

Platforms: Android (primary, signed release APK via CI), iOS, macOS, Linux, Windows. CI builds only the Android arm64 release APK; no iOS signing configured in CI.

## Current status

Working: device scan/connect, handshake, time sync, capability detection, find-device, today's steps/calories, live heart-rate, notification enable, factory reset, offline-first cloud toggle, firmware fetch-and-store + OTA flow.

Needs live-capture verification (flagged in `PROTOCOL.md` §8.5): battery push opcode, ECG/PPG notify opcodes, legacy APK-layer bind (`0x10`) layout, and remaining health-history field splits. Channel B CRC is resolved as CRC-16/MODBUS from firmware. Health history reads (HR/sleep/sport) and watch-face upload are scaffolded but not yet surfaced in the UI.

## Codebase architecture

The code is split into BLE transport, pure protocol codecs, services, and feature screens.

```
lib/
  main.dart                  # entrypoint: load Android user certs, init OTel, runApp
  core/
    ble/                     # GATT transport (flutter_blue_plus)
    protocol/                # PURE codec — no BLE, no async, fully unit-testable
    services/                # business logic + stateful managers
    providers/               # Riverpod wiring (app_providers.dart)
    routing/                 # go_router shell
  features/                  # one folder per screen
```

### The watch protocol in one paragraph

Two logical GATT channels on one connection:
- **Channel A** (`6e40fff0`) — 16-byte command frames `[opcode][sub..14][checksum]` with an additive 8-bit sum; write-with-response, opcode-correlated responses, gated behind a handshake (read HW/FW revision → `ready`).
- **Channel B** (`de5bf728`) — `0xBC`-magic, length-prefixed, CRC-16/MODBUS-protected large payloads sliced into MTU-sized chunks; used for OTA, files, and custom watch faces.
- **Vendor `0xFEE7`** (optional) — parallel 16-byte command path; SpO2, find-phone, vibration, OTA triggers. See `GHIDRA_DECOMPILATION.md` §8.

`PROTOCOL.md` is the single source of truth for opcodes, encodings, and CRC variants. Do not invent fields — if a value isn't documented there, treat it as "needs live capture" (the §8.5 list calls out battery push, ECG/PPG, bind layout, and remaining health-history splits).

### Layering (read top-to-bottom)

- **`lib/core/ble/ble_transport.dart`** — GATT connection lifecycle (`LinkState`: `disconnected → connecting → discovering → readingDeviceInfo → ready`), a single serialized write queue, opcode-correlated response waiters. Every inbound frame, every GATT write, and every request is wrapped in an OTel span.
- **`lib/core/protocol/codec.dart`** — pure byte helpers (`buildChannelA`, `isValidChannelA`, `rxOpcode`, `rxOpcodeRaw`). The top bit (`0x80`) is the **error flag on Channel A only**; on `0xFEE7` the top bit is part of the opcode namespace, so use `rxOpcodeRaw` there.
- **`lib/core/protocol/{channel_a,channel_b,fee7_dispatcher}.dart`** — typed views that subscribe to `transport.inboundA/B/fee7Inbound` and expose typed streams (e.g. `onBattery`, `onHeartRate`, `onPushMsg`).
- **`lib/core/services/protocol_hub.dart`** — `ProtocolHub` composes the dispatcher, parser, ANCS mirror, and (when present) the `0xFEE7` service into one handle. `WatchManager` is the only consumer that adds side effects (time sync, capability probe, timers).
- **`lib/core/services/watch_manager.dart`** — the high-level device manager. Runs the post-connect handshake, keeps live state (battery, steps, calories, HR), exposes management actions. Listen with `ChangeNotifier`-style `ref.watch(watchManagerProvider)`.
- **`lib/core/services/history_sync.dart`** + **`history_store.dart`** — local-first history. `HistorySync` is a `ChangeNotifier`; `HistoryStore` is the on-disk mirror under `<app docs>/history/`. The provider auto-fires an incremental `syncAll()` on `LinkState.ready` transitions when the user opted in.
- **`lib/core/services/cloud_api.dart`** — **opt-in**. `cloudApiProvider` returns `null` unless the user enabled cloud sync; every call site must null-check. The app stays fully functional with cloud disabled.
- **`lib/core/services/firmware_service.dart`** — fetches firmware once (explicit user action) and stores it locally; flashing then runs offline.
- **`lib/core/services/opentelemetry_service.dart`** — process-wide OTel singleton; exports to `https://otel.k2.k8s.best`. Maintains a `currentSpan` stack because the OTel package does not ship a `currentContext` helper — push on listener entry, pop on exit. The route observer is attached to `GoRouter.observers` (not `MaterialApp.router.navigatorObservers` — that one misses go_router pushes).
- **`lib/core/providers/app_providers.dart`** — every Riverpod provider lives here. **Do not `watch` `settingsProvider` inside `watchManagerProvider`** — it would rebuild on async prefs hydration and spawn a duplicate `WatchManager` + duplicate handshake. Use `ref.read` + `ref.listen` for that one-way handoff.

### Routing

`go_router` with a `StatefulShellRoute.indexedStack` for the bottom tabs (dashboard / health / notifications / settings) and root-level routes for `scan` (entry), `firmware`, `logs`, `history`. `initialLocation: '/scan'`. Adding a tab = adding a branch to `StatefulShellBranch`; adding a non-tab screen = a top-level `GoRoute` with `parentNavigatorKey: _rootNavigatorKey`.

### Observability — quick reference

Tracing is on by default; metrics/logs/auto-log-events are off (mirrors `happy_flutter`). When adding instrumentation:
- Use `OpenTelemetryService().startTrace(name, kind: SpanKind.X, attributes: {...})` — returns `null` until OTel init completes, so callers can `?.end()`.
- Long-lived listeners should `pushCurrentSpan` on entry and `popCurrentSpan` on exit so child spans parent correctly.
- HTTP interceptors should read `currentSpan` to parent their outbound span.
- Android-only: `lib/main.dart` loads the OS user-installed CA store via `flutter_user_certificates_android` so the OTLP/HTTPS collector trusts corporate MITM certs.

## Tests

`test/` mirrors the protocol layer 1:1 — every codec, dispatcher, parser, and state machine has a focused unit test. Tests for BLE code use a `_StubTransport` implementing `BleTransport` via `noSuchMethod` so the protocol layer can be exercised without a device. Keep new protocol code accompanied by a test under `test/`.

## CI

`.github/workflows/flutter.yml` runs `flutter pub get → dart format --check → flutter analyze → flutter test`, then (on master/main/explicit `v*` tag) builds + uploads the Android arm64 release APK and creates a GitHub Release. Green CI is the bar; run `mcp__gh-actions__list_runs` and `mcp__gh-actions__diagnose_failure` after pushing.

## Commit conventions

Conventional commits (`type(scope): subject`). Branches use `type/what` (e.g. `fix/otel-auto-pop`). See recent commits for tone — short, lowercase scope, body explains the *why*. The current commit log shows a mix of `fix(otel):`, `fix(history):`, `fix(main):` reflecting recent protocol/stability work.
