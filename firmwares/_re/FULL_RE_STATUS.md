# H59MA v14 — Full Static RE Status

Date: 2026-07-08  
Artifact: `firmwares/_re/v14/body.bin` (136 700 B)  
Base: flash = body + `0x00826400`  
Language: ARM Thumb-2 / Realtek RTL8762x

## Executive summary

Static reverse engineering of the **OTA app body** is effectively complete for
host-protocol work. Every wire opcode in the Channel-A deferred tree, the
vendor/high immediate path, and the Channel-B async cascade has a documented
handler address and request/response shape. History producers, settings
stores, health/gsensor control, OTA state machine, and the main `qc_app_task`
tick order are mapped.

What remains is **not missing firmware analysis of this image** — it is either
(1) semantic labels that require live capture / UI correlation, (2) code that
does not exist in this image (bootloader, ECG/PPG), or (3) phone-side APK
behavior (cloud `@RequiresSignature`, host meaning of opaque host blobs).

| Layer | Static coverage | Notes |
|---|---:|---|
| Container / header | ~100% | Digest algorithm unknown; staged not validated by app body |
| BLE GATT tables | ~100% | Channel A/B + FEE7 + DIS |
| Channel-A framing + deferred dispatch | ~100% tree | All cmp arms inventoried |
| Vendor/high 16-byte dispatch | ~95% wire | `0xa0` flag human labels open |
| Channel-B framing/CRC/async | ~95% | Placeholder cmds confirmed |
| OTA/DFU SM | ~90% | Matches `dfu.dart`; digest not checked here |
| History producers | ~90% layout | Clinical stage names open |
| Settings / alarms / config | ~90% | Most offsets named |
| Health + gsensor | ~90% | Masks + frames + LIS3DH regs |
| ANCS client | ~85% | Documented in GHIDRA §4 |
| Soft-float / libc / ROM | N/A | Runtime helpers only |
| Bootloader / lower flash | **0%** | Not in OTA image |

**Overall static host-protocol completeness: ~92–95%.**

## Evidence tree (authoritative)

| Dir | Topic |
|---|---|
| `ble-hunt/`, `ble-validate/`, `gatt-table/` | GATT / UUIDs |
| `channel-b-dispatch/`, `channel-b-payloads/` | Channel-B routing + wire sizes |
| `ch-a-dispatch-audit/` | Deferred dispatcher address audit (rejects +0x50 claim) |
| `vendor-high-audit/`, `fee7-high/`, `fee7-gatt/` | Vendor/high + FEE7 GATT truth |
| `health-measure/`, `health-sensor/` | Live measure + masks + gsensor |
| `bp-history/`, `bp-slot-encoding/` | BP wire + 4-byte slots |
| `history-layouts/` | Sleep/activity/HR/pressure/HRV producers |
| `settings-maps/`, `config-blob/` | blob0/blob1/user_config/cfg items |
| `period-data/` | Menstruation host blob store/echo |
| `ota-container/`, `digest-and-boundary/` | OTA container + digest negatives |
| `h59-file-table/` | File list/transfer |
| `protocol-complete/`, `full-opcode-inventory/` | Residual completeness + tables |
| `protocol-validate/`, `strings-mining/`, `diff/` | Early scans |

Narrative docs: `firmwares/GHIDRA_DECOMPILATION.md` (primary),  
`firmwares/FIRMWARE_ANALYSIS.md` (bytes), `PROTOCOL.md` (host spec).

## Opcode surfaces (complete trees)

### Channel-A deferred (`channel_a_dispatch_queued_frame` @ `0x0082d2dc`)

27 cmp targets: 24 active handlers + `0x14`/`0x7d` no-ops. Full table:
`full-opcode-inventory/inventory.md` §A. Entry verified by
`ch-a-dispatch-audit` (only BL from `qc_app_task`).

### Vendor/high immediate (`0x0082c5f6`, guard `0x0082c944`)

- Low switch: camera/battery/bind/settings/BP/alert/HR/degree/targets + deferred set
- High switch: `0x90..0xa0`, `0xce`, `0xfe`, memory R/W, capability, lipids, …
- `0x9d` → vendor NAK `[op|0x80, 0xee]` (not silence)
- FEE7 GATT write is **not** the 16-byte dispatcher entry

### Channel-B async

First-stage CRC + routes; async low OTA `0x00..0x10`; cascade sleep/activity/
alarm/file/device-info; explicit NAK and no-op placeholders.

## History layouts (producer truth)

| Store | Layout | Host opcode |
|---|---|---|
| Sleep summary 100 B | start/end min, pair count, type/dur arrays, type buckets 2/3/5 | Ch-B `0x11`/`0x27` |
| Sleep/sport hourly 24×12 B | stepsΔ, metric38Δ, cal/100, dist/10, elapsed-low; +9..11 unused live | Ch-B `0x12`, Ch-A `0x43` |
| Activity daily 24×2 | **(max_u8, min_u8)** SpO2-like domain ≤100; **not** steps | Ch-B `0x2a` |
| HR 5-min | key + **288 × u8 BPM** | Ch-A `0x15` |
| BP hourly | `[compact,0,0,0]` compact=HR or PRNG 70–74 | Ch-A `0x0d`/`0x0e` |
| Pressure / HRV | 48 × u8 half-hour scores | Ch-A `0x37` / `0x39` |

Sleep type constants `{0,2,3,4,5}` recovered; **clinical stage names need live capture**.

## Settings stores

| Store | Len | Magic | Highlights |
|---|---:|---|---|
| blob0 | `0xe0` | `0x04` | watchface, TLV strings, MAC, session mode |
| blob1 | `0x2b0` | `0x07` | feature bits, DND, alarms (10×0x29), sedentary, menstruation |
| user_config | `0xa4` | `0xa1b2c3e5` | RTC/tick; wiped on factory reset |
| cfg items | var | `0x8721bee2` | item `0x33` MAC only in this body |

## Health / sensors

- Sensor masks: HR `1`, BP auto `4`, SpO2 manual `0x20` / auto `0x80`, HRV `0x100`, pressure `0x200`, sugar `0x400` (synthetic), temp `0x1000` (stub=0), realtime HR `0x2000`, …
- Live frames: `0x69` progress/value + `0x6a` stop; layouts in `health-sensor/evidence.md`
- LIS3DH on bus `0x19`; FIFO → step path → sport totals
- Body temp: pure stub; blood sugar: synthetic PRNG path

## OTA

States `0→1→2→3→4→5`; init 9 B; data pocket max `0x600`; magic `0x81bdc3e5`; strip `0x50`; completion = size check only.  
`image_digest @0x1c4`: exhaustive hash/HMAC/CRC/structure search **negative** in app body; bootloader not present.

## `qc_app_task` tick order

Deferred Channel-A drain → secondary ring → Channel-B async processor → timers / UI / sensor ticks (see `protocol-complete/evidence.md`).

## Explicit non-goals / hard limits

| Item | Why static RE stops |
|---|---|
| ECG / PPG notify opcodes | Absent from v14 image; mode `0x07` falls through |
| `image_digest` algorithm | No app xrefs; needs bootloader dump |
| Sleep type → deep/light/REM labels | No strings; only integer constants |
| Live BP sys/dia ↔ cuff mmHg | Synthetic from HR+PRNG; needs cuff capture |
| `periodData` host meaning | Firmware store/echo only |
| `@RequiresSignature` cloud set | APK Retrofit, not firmware |
| File fieldId product names | Offsets only in firmware |
| `0xa0` flag human labels | Sources mapped; product names open |

## Recommended next steps (outside static body RE)

1. Live capture: sleep stage correlation, SpO2 confirm for `0x2a`, cuff vs `0x69` BP.
2. Acquire bootloader/lower-flash image for digest validation path.
3. APK RE for cloud signature set and `periodData` UI fields.
4. Optionally align OpenWatch `HistorySync._activityTotalsFromBody` with SpO2 max/min interpretation of `0x2a` (currently best-effort step totals — may be wrong vs producer).

## Confidence legend

- **High** — disassembly + sole xref + write path closed.
- **Med** — layout closed, unit/label inferred.
- **Low / live** — needs device capture.
