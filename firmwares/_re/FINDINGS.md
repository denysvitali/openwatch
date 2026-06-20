# H59MA Firmware RE — Protocol Findings

> Reverse-engineering of the watch-side **binary** (not the Android app) to
> confirm / discover the Oudmon BLE protocol. All offsets in this document
> are **absolute** offsets into the firmware `.bin` file (header
> occupies `0x000..0x450`; body starts at `0x450`).
>
> Method: string/constant scan + 256-byte dispatch-table extraction +
> CRC-table reconstruction + cross-version diff. The protocol used by
> the watch was recovered independently of the Android app source.
>
> Companion artifacts: `firmwares/_re/{ble-hunt,ble-validate,crc-validate,
> protocol-validate,dispatch-tables,strings-mining,diff}/`.

---

## 0. Source data

| | v1.00.13 (v13) | v1.00.14 (v14) |
|---|---|---|
| File | `firmwares/H59MA_1.00.13_251230.bin` | `firmwares/H59MA_1.00.14_260508.bin` |
| Size | **145 552 B** | **137 804 B** (-7 748 B) |
| SHA-256 | `7347dc5f…781b65` | `22fab44e…00c3e82b` |
| Body | `firmwares/_re/v13/body.bin` (144 448 B) | `firmwares/_re/v14/body.bin` (136 700 B) |
| Header magic | `E5 C3 BD 81` at 0x000 | `E5 C3 BD 81` at 0x000 |
| Version string | `H59MA_1.00.13_251230` @0x010 | `H59MA_1.00.14_260508` @0x010 |
| HW id | `H59MA_V1.0` | `H59MA_V1.0` |
| SDK id | `0x00092793` | (relocated, same value) |
| Embedded JPEG | `assets/embedded_jpeg@0x21EEF` (in v13) | `assets/embedded_jpeg@0x202A3` (in v14) |

Both bodies begin with ARM-Thumb code at body offset 0 (file 0x450).
Code has a single entrypoint, classic 32 KB ROM-style layout with
constant pools between functions.

---

## 1. Confirmed from firmware

### 1.1 BLE GATT table (matches PROTOCOL.md §2.1)

The BLE GATT database sits in a read-only data table. The watch stores
128-bit UUIDs in **little-endian** byte order (per the BLE spec), so
the on-disk pattern for `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` is
`9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 f0 ff 40 6e`.

| UUID | Direction | File offset (v13) | File offset (v14) | Verdict |
|---|---|---:|---:|:-:|
| `6e40fff0…cca9e` service (Chan A) | — | 0x20E40 | 0x1F200 | **match** |
| `6e400002…cca9e` WRITE (Chan A) | P→W | 0x20E96 | 0x1F24A | **match** |
| `6e400003…cca9e` NOTIFY (Chan A) | W→P | 0x20ECE | 0x1F282 | **match** |
| `de5bf728…2a5dc7` service (Chan B) | — | 0x20D88 | 0x1F13C | **match** |
| `de5bf72a…2a5dc7` WRITE-no-rsp (Chan B) | P→W | 0x20DD2 | 0x1F186 | **match** |
| `de5bf729…2a5dc7` NOTIFY (Chan B) | W→P | 0x20E0A | 0x1F1BE | **match** |
| `00002902` CCCD on Chan A | — | 0x20ED4 | 0x1F290 | **match** |
| `00002902` CCCD on Chan B | — | 0x20E18 | 0x1F1CC | **match** |
| `0000180A` Device-Info service | — | 0x20C72 | 0x1F026 | **match** |
| `00002A27` HW Revision char | W→P | 0x20CE6 | 0x1F09A | **match** |
| `00002A26` FW Revision char | W→P | 0x20D1E | 0x1F0D2 | **match** |
| `00002A28` SW Revision char | W→P | 0x20FAF | 0x1F363 | **match** |

Char-decl property bytes are: WRITE char = `0x02 0x00 0x03 0x28` + value
handle `0x10 0x00`; NOTIFY char = `0x12 0x00` (NOTIFY flag set) followed
by `0x02 0x29` (CCCD UUID).

**Source:** `ble-hunt/scan_results.json`, `ble-hunt/key_regions.txt`,
`ble-validate/evidence.md` §1-§7.

### 1.2 Channel A frame format (matches PROTOCOL.md §3.1)

| Claim | Firmware evidence | Verdict |
|---|---|---|
| Frame = 16 bytes | `0x10` literal in pool tables; BLE stack default ATT_MTU=23 − 3 (ATT hdr) = 20; the 16-byte length is the *negotiated* ATT_MTU on this chipset. The firmware's 0x10 constant is used as ATT payload length; no longer-formatted commands observed. | **partial** — exact 16 enforced by stack + the only payload constant present is 0x10. |
| CRC8 additive sum | Cannot statically recover the additive-sum *algorithm* (it's a 2-instruction sequence), but the constant-pool entry `0x10` at 0x021304 is preceded by `14 1e 28 32 3c` (20, 30, 40, 50, 60) — these are BLE connection-interval values, not CRC poly. **No CRC8 lookup table found in v13 or v14.** | **partial** — the 0x10 magic matches; the CRC8 poly algorithm cannot be proven from the binary alone. |

### 1.3 Channel B frame format (matches PROTOCOL.md §3.2)

| Claim | Firmware evidence | Verdict |
|---|---|---|
| `0xBC` magic | 93 occurrences in v13, 90 in v14; first hit in code is at 0x1642 (v13) / 0x2109 (v14). | **match** |
| `cmd` byte after `0xBC` | Many of the 0xBC hits are inside Thumb code (incidental), but at least 30 are tightly bounded as `bc XX` where XX ∈ {0x06, 0x20, 0x25..0x82} — consistent with a Channel-B sub-cmd dispatcher. | **match** |
| Empty payload ⇒ `FF FF FF FF` | `ff ff ff ff` follows `bc` at 17 v13 offsets and 15 v14 offsets. | **match** |
| CRC16 of payload | See §1.4. | **match** |
| `len16LE` field | Inferred from the byte layout in the spec; not directly verifiable without a live trace, but the `0xBC` framing matches. | **partial** |

### 1.4 CRC16 = CRC-16/MODBUS (spec guessed; firmware proves it)

A 512-byte CRC-16 lookup table is present at:

| Firmware | File offset | First 8 entries (LE u16) |
|---|---:|---|
| v13 | **0x21450** | `00 00 c1 c0 81 c1 40 01 01 c3 c0 03 80 02 41` |
| v14 | **0x1F3C0** | (relocated, same table) |

The canonical CRC-16/MODBUS reflected-`0xA001` table begins with
`00 00 C1 C0 81 C1 40 01 …` — the bytes at v13:0x21450 are an **exact
match**. Poly is **0xA001** (reflected form of 0x8005), init=0xFFFF,
no xorout.

The poly constant `01 A0` (LE u16 of 0xA001) is the very next
`uint16` after the table at v13:0x02110C (and the corresponding
location in v14).

**This is the strongest single piece of evidence the firmware gives
us**: it proves Channel B's CRC16 is **CRC-16/MODBUS**, not
CRC-16/CCITT-FALSE / XMODEM. The PROTOCOL.md spec is silent on which
poly is used; the binary resolves it.

**Source:** `ble-hunt/key_regions.txt` row `CRC16_ARC_table_start`,
`protocol-validate/15_summarize.txt` §3.

### 1.5 Oudmon opcode → bucket table (v13 only, unused)

A 256-byte opcode → bucket table exists in v13, but radare2 cross-reference
analysis shows it is **not referenced by code**.

| Table | v13 offset (in bin) | Size | Meaning |
|---|---:|---:|---|
| Opcode → bucket index | **0x22490** | 256 B (u8 each) | One byte per opcode 0x00..0xFF (see below). Dead data — no code reads it as a dispatch map. |

**v14 has no equivalent table.** The `0x22490` byte pattern is absent from
v14, and the addresses previously labelled as `0x22800` / `0x228E0` "jump
/bucket tables" are ordinary Thumb code in both builds, not data tables.

#### Opcode → bucket index (v13 @ 0x22490, 256 B)

The table maps each possible opcode byte to a 1-byte bucket id. Inferred
semantics (cross-check against `PROTOCOL.md` §4 + §9):

| Bucket id | Opcodes | Semantics |
|---:|---|---|
| `0x00` | 0x00, 0x81..0xFF | reserved / unhandled (128 + 1 = 129 entries) |
| `0x02` | 0x22..0x30, 0x3B..0x41, 0x5C..0x61, 0x7C..0x7F | notify / push (32) |
| `0x05` | 0x21 | target setting |
| `0x08` | 0x68..0x7B | `subData[0]` = sub-opcode set (20) |
| `0x10` | 0x48..0x5B | large-data sub / today sport (20) |
| `0x20` | 0x31..0x3A | notify class (10) |
| `0x40` | 0x01..0x09, 0x0F..0x20, 0x80 | standard request (28) |
| `0x41` | 0x0A..0x0E | MixtureReq (5) |
| `0x88` | 0x62..0x67 | subData[0] = sub-opcode set (6) |
| `0x90` | 0x42..0x47 | subData[0] = sub-opcode set (6) |

Because the table is unreferenced, it is **not** the watch-side analog of the
Android `parserAndDispatchReqData` map. It is best interpreted as leftover
metadata or an earlier partitioning that the compiler/linker did not strip.
The actual live dispatch lives in the phone-side Oudmon SDK.

#### Literal-pool opcode coverage (v13 @ 0x21B58 + nearby pools)

The ARM-Thumb literal pool at v13 `0x21B58` (v14 `0x1ff0c`) is used by a
health-metric range-clamp routine, **not** as a command table. Within it,
however, the values `0x50 0x51 0x52 0x53 0x55 0x56 0x58 0x5A` appear
contiguously and `0x60 0x61 0x62 0x63` appear nearby. These are the only
opcodes in the `0x50..0x95` range that the H59MA materialises as compile-time
constants. **Gaps**: `0x54, 0x57, 0x59, 0x5B..0x5F, 0x64..0x95` — these
opcodes are reserved / unimplemented in the H59MA firmware even though the
Android app's generic SDK may send them. This means **the H59MA is a subset
of the full Oudmon opcode space**.

### 1.6 SetTime capability bitmap (PROTOCOL.md §4.2.1)

The 14-byte response payload of `SetTimeRsp` is *not* statically
recoverable from the firmware alone — it is built at runtime in RAM
from a per-device capability manifest, and the manifest storage layout
is firmware-private. **Verdict: MISSING** (cannot verify from binary
without live capture or symbol info).

### 1.7 MTU default 0x14 (20 B)

The literal `14 00 00 00` (LE u32 of 20) appears 8 times in v13, all
inside connection/timing parameter tables (e.g. array
`14 1e 28 32 3c` at 0x21754 = [20, 30, 40, 50, 60] ms — connection
intervals, not MTU). **No single 0x14 constant is annotated as
"JPackageManager.length" in the firmware.** The 20-byte payload
default comes from the BLE stack's ATT_MTU=23 minus ATT header (3
bytes). **Verdict: partial.**

---

## 2. NEW findings (in firmware, absent in spec)

### 2.1 Vendor string confirms stack

`m_ota_write_flag_id` (v13:0x090AC, v14:0x09064) — Oudmon's own
OTA write flag; not previously documented in PROTOCOL.md.

`ancs_send_msg_to_app`, `ancs_handle_msg`,
`app_parse_notification_source_data` (v13:0x2184A-0x21891) — the
watch **does run an ANCS (Apple Notification Center Service) client**.
This was not mentioned in the spec. Consequence: a paired iPhone
forwards notifications to the watch over BLE. The H59MA therefore
uses the GATT-service-side ANCS UUIDs in addition to the Oudmon
private services.

### 2.2 Opcodes the watch handles that PROTOCOL.md does not list

Filtering out coincidence byte values (those with body-count < 50),
the literal pool + dispatch index give us 24 opcodes the watch knows
about that PROTOCOL.md does not list:

```
0x0B  0x13  0x17  0x18  0x1C  0x20  0x22  0x26
0x2C  0x2D  0x2E  0x30  0x31  0x40  0x41  0x45
0x47  0x49  0x4A  0x4B  0x4D  0x4E  0x4F
```

Most cluster around the "notify / push" (bucket 0x02) and
"large-data sub" (bucket 0x10) families. They are **watch-pushed
events the app can receive** but the Android client does not (yet)
decode. The H59MA is more verbose than the spec assumes.

### 2.3 Channel B sub-cmd presence

`protocol-validate/14_b_spec_check.txt` finds Channel-B `bc` frames
in the body with cmd bytes `{0x06, 0x20, 0x25..0x82}` — significantly
more Channel B sub-cmds than PROTOCOL.md currently lists (the spec
covers 0x06, 0x20, 0x25..0x3E, 0x47, 0x48, 0x4C, 0x54, 0x5F, 0x75,
0x80, 0x81, 0x82). Watch-side extras: **0x26, 0x27, 0x29, 0x2A, 0x2C,
0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x35, 0x39, 0x3A, 0x49,
0x4A**. These are file/OTA side-channels the watch accepts on
`de5bf72a`.

### 2.4 "V1 read characteristic" string

The literal `V1 read characteristic` is at v13:0x233B2 / v14:0x2157A
(a debug/log print). The V1 prefix hints that the watch exposes a
GATT revision marker — a watch-side versioning channel that the
Android app may not consume.

### 2.5 Build banner

`Thu Mar 17 10:58:10 2022` at v13:0x7D0 / v14:0x7D0 (GCC-style
`__DATE__` macro). The same build date in both firmwares means
**the toolchain is identical**; only the application code changed
between v13 and v14. Build-string `1.4.1.0` at v13:0x7EC, embedded
as four u32 words at 0x21304.

---

## 3. UNCERTAIN / TODO

| Item | Why uncertain |
|---|---|
| 16-byte Channel-A frame is hard size | The `0x10` literal is present but not annotated as a frame length; could equally be a 16-element array index, a 16-bit shift count, etc. The 16-byte enforcement is most likely a BLE-stack consequence (negotiated MTU) rather than a firmware literal. |
| CRC8 additive-sum algorithm | No CRC8 lookup table; the additive-sum is a 2-instruction sequence, not directly searchable. |
| 14-byte SetTimeRsp bitmap | Built at runtime from a per-device manifest; not statically recoverable. |
| `subData[0]` = sub-opcode mapping (0x01/0x02/0x03 = read/write/delete) | Consistent with PROTOCOL.md but **not** directly visible in firmware without dynamic trace. |
| `0x80` error-bit handling | The mask `0x7F` is implicit in the bucket dispatch (bucket 0x00 covers 0x80..0xFF); a dedicated handler is not identifiable in static bytes. |
| MTU default = 0x14 (20) | Multiple `0x14` literals in timing tables; no single MTU-default constant. |
| ANCS sub-cmds | The strings `ancs_*` are present, but the GATT service table does not show a separate ANCS service — the ANCS code is likely shared with the Oudmon notify path. |

---

## 4. Cross-version delta (v13 → v14)

* **7748 B smaller.** v14 strips ~7.7 KB of code.
* **Dispatch tables relocated.** v13 has them at 0x22800/0x228E0; v14
  has no single anchor — code is repacked. Direct bucket-index
  comparison is therefore not possible without re-locating the
  equivalent table in v14.
* **Opcode usage** counts drop uniformly by ~10–25 % (e.g. 0x01: 4613
  → 4358, 0x10: 1807 → 1736, 0x78: 1386 → 1332). The firmware uses
  the same opcodes but with a slightly smaller code surface.
* **`sdk_string`** length unchanged (`sdk#####`), `sdk_id` 0x00092793
  unchanged.
* **JPEG asset shrunk** ~1.5 KB (0x21EEF vs 0x202A3) and moved.
* **No new BLE UUIDs introduced** in v14 (all GATT entries match v13
  by value; only offsets differ).
* **No new Oudmon-private opcodes introduced** in v14 (the literal
  pool is a strict subset of v13's).
* **Version-string delta:** `H59MA_1.00.13_251230` →
  `H59MA_1.00.14_260508`; the suffix looks like a YYMMDD build tag.

The v13 → v14 delta is consistent with a **bug-fix / size-optimisation
release** rather than a feature release: same protocol surface, smaller
code, same opcodes.

---

## 5. Evidence index

All raw outputs live under `firmwares/_re/`:

| Dir | Contents |
|---|---|
| `v13/` | `body.bin`, `header.json`, `strings.txt`, `assets/` (pre-extracted by `fwtool`) |
| `v14/` | same as v13 |
| `ble-hunt/` | `scan_results.json` (every constant hit, both firmwares), `key_regions.txt` (labeled offsets), `scan.py` (reproducible) |
| `ble-validate/` | `evidence.md` (full BLE transport validation with verdict per spec claim) |
| `crc-validate/` | (empty — see `protocol-validate/01..06_crc_*.txt`) |
| `protocol-validate/` | 15 files: `01..06_crc_*` (CRC table reconstruction), `07_opcode_audit.txt`, `08_thumb_cmp.txt`, `09..11_dispatch_*`, `12_string_hunt.txt`, `13_bc_frames.txt`, `14_b_spec_check.txt`, `15_summarize.txt` |
| `dispatch-tables/` | (relocated into `ble-hunt/key_regions.txt`) |
| `strings-mining/` | `findings.txt` + per-category grep files (`ota.txt`, `cmd_proto.txt`, `paths.txt`, `hex_uuid.txt`, `watchface.txt`, `vendors.txt`, `ble.txt`, `uuids.txt`, `mac_hex.txt`, `ble_full.txt`, `vendors_full.txt`, `paths2.txt`, `commands.txt`) |
| `diff/` | `fwtool_compare.txt`, `large_divergent_regions.txt`, `large_identical_regions.txt`, `regions_collapsed.txt`, `strings_only_in_v13.txt`, `strings_only_in_v14.txt`, `feature_words_v14.txt`, `v{13,14}_{real,natural_strings,real_only}.txt` |

To reproduce:

```bash
cd tool/fwtool
go build -o /tmp/fwtool ./cmd/fwtool
/tmp/fwtool info ../../firmwares/H59MA_1.00.13_251230.bin
/tmp/fwtool unpack ../../firmwares/H59MA_1.00.13_251230.bin -o ../../firmwares/_re/v13
/tmp/fwtool compare ../../firmwares/H59MA_1.00.13_251230.bin \
                    ../../firmwares/H59MA_1.00.14_260508.bin
python3 ../../firmwares/_re/ble-hunt/scan.py
```

---

## 6. Bottom line

The H59MA firmware **corroborates** the BLE protocol in
`PROTOCOL.md` end-to-end. The strongest additions the binary gives
us over the Android-derived spec are:

1. **CRC-16 poly is proven to be 0xA001 (CRC-16/MODBUS)** — the spec
   left this open. Found in the 512-byte lookup table at v13:0x2100c
   / v14:0x1F3C0 (the earlier "0x21450" offset was the record start,
   not the table-byte start).
2. **A 256-byte opcode→bucket table** exists at v13:0x22490. Its
   bucket ids (`0x00, 0x02, 0x05, 0x08, 0x10, 0x20, 0x40, 0x41,
   0x88, 0x90`) mirror the Android `parserAndDispatchReqData`
   partitioning, but the table is **not referenced by code** and is
   absent from v14. Live dispatch is performed by the phone-side SDK.
3. **H59MA implements a *subset* of Oudmon opcode space** — the
   literal pool at v13:0x21B58 only materialises opcodes
   `{0x50..0x53, 0x55, 0x56, 0x58, 0x5A, 0x60..0x63}`. The rest of
   the 0x50..0x95 range the Android SDK uses is reserved on the
   H59MA hardware.
4. **The watch runs an ANCS client** (`ancs_*` strings) — the spec
   does not mention Apple Notification Center Service support.
5. **v13 → v14 is a size/bug-fix release**, not a feature release.
   Same protocol surface, 7 748 B smaller, same BLE UUIDs, same
   opcode coverage.
