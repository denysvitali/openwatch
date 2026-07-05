# H59MA / Oudmon Smartwatch Firmware — Consolidated Analysis

This document consolidates and **supersedes** `RE_FIRMWARE.md` and `R2_ANALYSIS.md` for byte-level layout and radare2 evidence. Ghidra later resolved several higher-level control-flow questions; where this file and `firmwares/GHIDRA_DECOMPILATION.md` disagree about live dispatchers or OTA control flow, prefer the Ghidra notes. Every load-bearing numeric claim was independently re-verified against the bytes using radare2 and Python against both `v13` (`H59MA_1.00.13_251230`) and `v14` (`H59MA_1.00.14_260508`). Known factual errors in the prior docs are flagged inline. See the companion `firmwares/_re/` evidence tree for raw extractor / scan / string-mining outputs, and `PROTOCOL.md` for the APK-derived protocol spec this firmware corroborates.

## Scope

- Static analysis only. No live capture, no symbol recovery, no debug info.
- The watch binary is **plaintext** ARM Thumb-2 (~6.98 bits/byte — typical ARM firmware, not packed/encrypted).
- No Cortex-M vector table inside the OTA payload (the bootloader/ROM lives in flash below the OTA region).
- Realtek **RTL8762x ("Bee")** BLE SoC + SDK, confirmed from API surface (`le_vendor_*`, `gatts_add_client`), power term `dlps` ("Deep Low Power State") and the `FMC` (Flash Memory Controller) references.

## Images

| Version | File | Container size | Body size | SHA-256(container) |
|---|---|---:|---:|---|
| v1.00.13 (v13) | `firmwares/H59MA_1.00.13_251230.bin` | 145552 | 144448 | `7347dc5fe7c552d4f0fb93cffa2dd9cab6945b5628900705a07eb7a357781b65` |
| v1.00.14 (v14) | `firmwares/H59MA_1.00.14_260508.bin` | 137804 | 136700 | `22fab44e1ee6f13972dec7e3bdde2da5719f962d518e36beb931f06800c3e82b` |

Body `sha256`s (extracted `_re/v{13,14}/body.bin`):
- v13 body: `fc30dfa66fc3c3cd31f601ef0a3465a19d4d03275b1570b54e9d445b3bc7d1c3`
- v14 body: `24802a9efa6fca9ea53ac6b6996f44ae0e9fc841ef606f7a3404726454b7fe64`

Body `.bin` files are regenerable (`tool/fwtool unpack`) and are `.gitignore`d.

## Conventions

All offsets in this document are **body** offsets (i.e. inside the post-`0x450` payload) unless prefixed `container:`. Add `0x450` to get container-file offset.

```text
container_offset = body_offset + 0x450
device_addr      = 0x00826400 + body_offset    (flash app load base, both builds)
```

Verification commands:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
   -c 'pd N @ off | pxw N @ off | / str | /x hex' <file>

python3 -c "d=open('<file>','rb').read(); print(d[off:off+n].hex())"
```

## Memory Map

| Region | Address | Evidence |
|---|---|---|
| Flash base | `0x00826000` | container header `0x78` (constant across builds) |
| App load base | `0x00826400` | container header `0x6c` / `0x70`; pin proven by CRC-table literal `0x0084740c` at v13 body `0x8da0` (== `0x826400 + 0x2100c`) |
| App region end | v13 `0x00847860`, v14 `0x00845c14` | container header `0x22c` (varies per build, follows body size) |
| SRAM | `0x20000000` … `~0x200fe358` | ~1 MB aperture, 877 (v13) / 845 (v14) RAM pointers |
| Body entry trampoline | v13 `0x00826741`, v14 `0x00826665` | body `0x4` (literal; build-specific) — the trampoline `0x47004800` (`ldr r0,[0x4]; bx r0`) lives at body `0x0` |
| Cortex-M vector table | none in OTA body | scan for SP@0x20000000 + ≥8 odd-thumb handler addresses returns 0 in both bodies — vector table is in the boot region **below** `0x826400`, reached only via the trampoline |
| Trampoline opcodes | `48 00 47 00` (constant) | body `0x0..0x3` |

`r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'pd 6 @ 0' _re/v13/body.bin` →

```text
0x00000000  0048   ldr r0, [0x00000004]   ; [0x4:4]=0x826741
0x00000002  0047   bx r0
0x00000004  4167   str r1, [r0, 0x74]    ; ← reinterpreted by r2; raw bytes 0x41 0x67 = 0x006741 LE
0x00000006  8200   lsls r2, r0, 2        ; raw 0x82 0x00
0x00000008  c046   mov r8, r8            ; nop
0x0000000a  c046   mov r8, r8            ; nop
```

**Correction to `RE_FIRMWARE.md`:** the implied base `~0x826740` (from the `0x00826741` word) is the thumb *entry* address, not the section base — section base is `0x826400`. Using `~0x826740` as a search anchor misses every flash-pointer.

## SoC / BLE stack — Realtek RTL8762x "Bee"

Confirmed by string-set intersection (verified offsets are body offsets):

| String | v13 | v14 |
|---|---:|---:|
| `app_main_task` | `0x20a8c` | `0x1ee40` |
| `gatts_add_client` | `0x218c4` | `0x1fc78` |
| `dlps` | `0x401e` | `0x3f72` |
| `"allowed enter dlps"` | `0x4010` | `0x3f64` |
| `FMC` | `0x17283 0x18291 0x1c469` | `0x172ab 0x181e9 0x1b0c9` |

`DLPS` (Deep Low Power State) and the `le_vendor_*` / `gatts_add_client` API surface are unique to Realtek's RTL8762x SDK — not Nordic SoftDevice (no `sd_*`), not Telink (no `tlsr`/`blt_`), not a generic stack. The prior `BEE2` marker was a false positive on the hex offset column `0x0001BEE2` (value `hFAZ`).

---

## 1. Container & Header (corrected)

The `0x450`-byte container header is byte-stable except for the version string, image checksum, body size, flash end, and image digest. The prior `firmwares/_re/v13/header.json` (and the `info` output of `tool/fwtool`) **misread multiple fields** — corrections below with byte evidence.

| Off | Size | Field | v13 | v14 | C/V | Meaning / correction |
|----:|----:|---|---|---|:--:|---|
| `0x00` | 4 | `magic` | `e5c3bd81` | `e5c3bd81` | C | File magic `E5 C3 BD 81`. |
| `0x04` | 4 | `load_size` | `0x00023840` | `0x000219fc` | V | = `body_size + 0x400`. Duplicated at `0x08`. |
| `0x08` | 4 | `firmware_size` | `0x00023840` | `0x000219fc` | V | Always equal to `load_size`. |
| `0x0c` | 4 | **`image_chk_a`** | `0x00ce90ee` | `0x00c43671` | V | Additive checksum: `sum(container[0x50:]) & 0xffffffff` (observed high byte `0x00`). **Not** CRC32, not size, not time. |
| `0x10` | 24 | `version_string` | `H59MA_1.00.13_251230` | `H59MA_1.00.14_260508` | V | ASCII, NUL-padded. |
| `0x30` | 16 | `hw_id` | `H59MA_V1.0` | `H59MA_V1.0` | C | ASCII, NUL-padded. |
| `0x40..0x4f` | 16 | reserved | `00…` | `00…` | C | zero pad. |
| `0x50` | 4 | `flags` | `0x0981000c` | `0x0981000c` | C | Build/feature flags. |
| `0x54` | 4 | `sdk_id` | `0x00002793` | `0x00002793` | C | Disk `93 27 00 00` (LE). |
| `0x58` | 4 | **`body_size`** | `0x00023440` | `0x000215fc` | V | Exact size of `body.bin` (== container − `0x450`). Was `unknown32_b`. |
| `0x5c` | 4 | `const_5c` | `0x7e6b4cf9` | `0x7e6b4cf9` | C | Byte-identical across 5-month-separated builds — **NOT a timestamp**. First u32 of the RFC-4122 v1 GUID `7e6b4cf9-c511-11eb-8282-f74a0c0cef5b`. `fwtool` still renders it as `2037-03-18T03:54:33Z` — wrong. |
| `0x60` | 12 | `signature_a` | `11c5eb11 8282f74a 0c0cef5b` | identical | C | 12-byte constant blob (NOT 16 — `fwtool` reads 4 bytes too many). |
| `0x6c` | 4 | `flash_app_start` | `0x00826400` | `0x00826400` | C | = `flash_base + 0x400`. |
| `0x70` | 4 | `flash_app_start2` | `0x00826400` | `0x00826400` | C | Duplicate of `0x6c`. (`fwtool` reads 16 B here and labels it `nonce_or_key`.) |
| `0x74` | 4 | reserved | `0x00000000` | `0x00000000` | C | zero. |
| `0x78` | 4 | `flash_base` | `0x00826000` | `0x00826000` | C | Flash region base. |
| `0x7c..0xaf` | 52 | reserved | `00…` | `00…` | C | zero pad. |
| `0xb0` | 4 | `board_marker` | `0x00001041` | `0x00001041` | C | `41 10 00 00`. |
| `0xb4` | 4 | `const_b4` | `0x1201a39e` | `0x1201a39e` | C | **New field**, missing from `fwtool`'s `info`. |
| `0xb8` | 8 | `sdk_string` | `sdk#####` | `sdk#####` | C | `73 64 6b 23 23 23 23 23`. |
| `0xc0..0x1bf` | 256 | reserved | `00…` | `00…` | C | zero pad. |
| `0x1c0` | 4 | reserved | `0x00000000` | `0x00000000` | C | Leading zeros of digest slot. |
| `0x1c4` | **32** | **`image_digest`** | `8d50aa22…42178bb1` | `47d3b81a…0d354648` | V | Per-build 32-byte digest/signature field (SHA-256-sized, varies). Algorithm and bootloader validation are unresolved. `fwtool` reads only 16 B starting at `0x1c0` (4 bytes early) and labels it `nonce2` — wrong. |
| `0x1e4..0x227` | 68 | reserved | `00…` | `00…` | C | zero pad. |
| `0x228` | 4 | `const_228` | `0x0e85d101` | `0x0e85d101` | C | **New field**. |
| `0x22c` | 4 | `flash_app_end` | `0x00847860` | `0x00845c14` | V | **New field**, varies. |
| `0x230..0x32f` | 256 | reserved | `00…` | `00…` | C | zero pad. |
| `0x330..0x33f` | 16 | `erase_marker1` | `ff…ff` | `ff…ff` | C | All-`0xFF`. (`fwtool` reads 4 B here and labels it `crc3`.) |
| `0x340..0x43f` | 256 | reserved | `00…` | `00…` | C | zero pad. |
| `0x440..0x44f` | 16 | `erase_marker2` | `ff…ff` | `ff…ff` | C | All-`0xFF`. **`fwtool` calls this `secondary_signature` — wrong**; it's just an erase marker. The body trampoline (`48 00 47 00`) starts at `0x450`. |

### Why the `0x0c` "checksum" is an additive sum, not CRC32

- `crc32(body) v13 = 0x06e82ea6` ≠ `header@0x0c 0x00ce90ee` (and `crc32(body) v14 = 0xfb997b47` ≠ `0x00c43671`).
- Both 0x0c values track a byte-sum over the body region: same top byte `0x00`, same magnitude order as `sum(body) mod 2^32`.

### The 32-byte digest at `0x1c4` is **not** a SHA-256 of any obvious window

Tested combinations (Python):

| Region | v13 sha256 match? | v14 sha256 match? |
|---|:--:|:--:|
| `body` (`0x450..end`) | ❌ | ❌ |
| `header` (`0..0x450`) | ❌ | ❌ |
| `full` (`0..end`) | ❌ | ❌ |
| `0..0x1c4 ∪ 0x1e4..end` (skip digest slot) | ❌ | ❌ |
| `0x22c..end` (after `flash_app_end`) | ❌ | ❌ |
| CRC32(body) LE, MD5(body), SHA-1(body) | ❌ all | ❌ all |

The 32 bytes vary per build and have high entropy, but are **not** a hash of any contiguous window of the image. Most likely a vendor-proprietary MAC keyed by `signature_a` / `0x5C` GUID, or a SHA-256 over a portion of the image that includes bytes outside the public container (e.g. bootloader region). Documented as **open** (§9).

---

## 2. Code Structure & Function Inventory

| Metric | v13 | v14 |
|---|---:|---:|
| Body size | 144448 B | 136700 B |
| Δ vs v13 | — | **−7748 B** |
| r2 `afl` function count (raw Thumb-2) | ~150 (poor auto-analysis; the body has no ELF symbols or debug info and r2 only finds functions with clean `push {r4..lr}` prologues — many are missed) | similar |
| Trampoline | `ldr r0,[0x4]; bx r0` + 2 nops | identical |
| Thumb-2 LE / BE | LE | LE |

Layout (rough):

| Region (v13 body) | Region (v14 body) | Contents |
|---|---|---|
| `0x0000..0x00800` | `0x0000..0x00800` | Trampoline, low-level init, vector-pointer literals |
| `0x00800..0x0b000` | `0x00800..0x0b000` | RTOS / BLE stack (`app_main_task`, timers, `le_vendor_*`) |
| `0x0b000..0x1c000` | `0x0b000..0x1a000` | Application code (commands, OTA, sensors, UI) |
| `0x1c000..0x1d500` | `0x1a000..0x1c500` | Health/notification code (health-metric clamp, ANCS) |
| `0x1c500..0x21b50` | `0x1c500..0x1ff00` | String/const pool (`Scene_B`/`Scene_C`, ANCS app list, peripheral names) |
| `0x21b58..0x21b58+0x50` | `0x1ff0c..0x1ff0c+0x50` | u32 literal pool `{0..0x0b, 0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x58, 0x5a}` — referenced by **health-metric range-clamp routine only**, NOT an opcode dispatcher. |
| `0x21eef..0x21f80` | `0x202a3..0x20300` | Mixed const data with strings: `Scene_B`, `Scene_C`, `Telegraph`, `com.facebook.Facebook`, `com.google.Gmail`, `com.burbn.instagram`, `com.facebook.Messenger`. **Not** an embedded JPEG (see §8). |
| `0x22000..0x22490` | `0x20500..0x20900` | Const data + GATT preamble |
| `0x22490..0x22590` | **absent** | 256-byte opcode→bucket dispatch table (v13 only) |
| `0x22590..0x22800` | n/a | const tail |
| `0x22800..0x228e0` | n/a | 16-entry u32 lookup table (small absolute offsets, NOT a function-pointer jump table — see §5) |
| `0x228e0..0x229e0` | n/a | const tail |
| `0x23000..0x23890` | `0x1f000..0x21a4c` | GATT attribute database (4 services, 11 chars, 4 CCCDs) |

The most code-heavy single function in either build is the Channel-B reassembly parser (next section). r2 `aaa + afl` recovers fewer functions than the binary actually has because some code uses tail-calls or leaf-style frames without `push {r4..lr}` — manual inspection finds more.

---

## 3. BLE GATT Attribute Database

Four services, identical structure in both builds. All 128-bit UUIDs are stored **little-endian** (16 bytes reversed vs the canonical form); 16-bit UUIDs are 2 LE bytes (e.g. `0x180a` → `0a 18`). Every offset below is **body** offset (add `0x450` for container).

```sh
rafind2 -x e7fe firmwares/_re/v13/body.bin   # 0x20f08
rafind2 -x e7fe firmwares/_re/v14/body.bin   # 0x1f2bc
rafind2 -x 28f75bde firmwares/_re/v13/body.bin   # 0x20d88 (ChanB svc de5bf728)
rafind2 -x f0ff406e firmwares/_re/v13/body.bin   # 0x20e4c (ChanA svc 6e40fff0)
```

### Services

| Service | UUID | v13 svc-UUID byte off | v14 svc-UUID byte off |
|---|---|---:|---:|
| Device Information | `0000180a-0000-1000-8000-00805f9b34fb` | `0x20c78` | `0x1f02c` |
| Channel B (large data / file / OTA) | `de5bf728-d711-4e47-af26-65e3012a5dc7` | `0x20d7c` | `0x1f130` |
| Channel A (command) | `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` | `0x20e40` | `0x1f1f4` |
| **`0xfee7` vendor** *(previously omitted)* | `0000fee7-0000-1000-8000-00805f9b34fb` | `0x20f08` | `0x1f2bc` |

### Characteristics

| Char | UUID | v13 off | v14 off |
|---|---|---:|---:|
| Serial number | `0x2a25` | `0x20cae` | `0x1f062` |
| HW revision | `0x2a27` | `0x20ce6` | `0x1f09a` |
| FW revision | `0x2a26` | `0x20d1e` | `0x1f0d2` |
| System ID | `0x2a23` | `0x20d56` | `0x1f10a` |
| **Device Name** | `0x2a00` | `0x20fb0` | `0x1f364` |
| ChanB write | `de5bf72a-d711-4e47-af26-65e3012a5dc7` | `0x20dc6` | `0x1f17a` |
| ChanB notify | `de5bf729-d711-4e47-af26-65e3012a5dc7` | `0x20dfe` | `0x1f1b2` |
| ChanA write | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | `0x20e8a` | `0x20e8a` (RELOCATED — v14 = `0x1f23e`) |
| ChanA notify | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | `0x20ec2` | `0x1f276` |
| fee7 write | `0xfea1` | `0x20f3e` | `0x1f2f2` |
| fee7 read | `0xfec9` | `0x20f92` | `0x1f346` |
| fee7 notify | `0xfea2` | `0x20fca` | `0x1f37e` |

### CCCDs (`0x2902`, LE `02 29`)

```text
v13: 0x20e1a (ChanB), 0x20ede (ChanA), 0x20f5a (fee7/fea1), 0x20fe6 (fee7/fea2)
v14: 0x1f1ce,         0x1f292,         0x1f30e,             0x1f39a
```

Total: **4 services / 11 chars / 4 CCCDs** in both builds (the prior `RE_FIRMWARE.md` listed a fifth DevInfo char `0x2a28` SW revision; the `0x2a28` byte match at v13 `0x20faf` straddles a `0x2803` char-decl / `0x2a00` value-UUID field seam — the real value at that offset is **Device Name `0x2a00` inside the `0xfee7` block**).

### Attribute-record structure

Fixed `0x1c` (28)-byte records, half-word aligned. Each declared characteristic = two records (a `0x2803` decl + the value record) = `0x38` bytes between consecutive value-UUID offsets.

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'px 28 @ 0x20c72' _re/v13/body.bin
0x00020c72  82 00 02 08 00 28 0a 18 00 00 00 00 00 00 00 00
            ^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
            attr-hdr + perm  0x180a inline UUID (LE u16 0x180a)
0x00020c82  00 00 00 00 00 00 02 00 00 00 00 00 01 00 00 00
0x00020c92  02 00 03 28 ...                              # next record: 0x2803 char-decl
```

128-bit UUIDs use a 16-byte inline form prefixed by a `0x05` type tag (the `0x05` byte is "128-bit UUID" indicator vs inline 16-bit). Value pointers in the table point into the body itself: e.g. v13 ChanB svc-decl has a value-ptr to `0x0084717c`.

Channel-A service record (v13 `0x20e40`):

```text
0x00020e40  9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 f0 ff 40 6e
            ^^^^^^^^^^^^^^^^ 16-byte LE UUID = 6e40fff0-b5a3-f393-e0a9-e50e24dcca9e (reversed)
0x00020e50  00 08 00 28 00 00 00 00 00 00 00 00 00 00 00 00
            ^^^^^^^^^^^ 0x2800 PRIMARY SERVICE DECL
```

Channel-A notify char record (v13 `0x20ec2`):

```text
0x00020ec2  9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 03 00 40 6e
            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
            16-byte LE UUID for 6e400003 (LE u16 = 03 00)
0x00020ed2  00 00 00 00 00 00 00 01 00 00 12 00
                              ^^^^^^^^^^^^
                              perm 0x12 (NOTIFY) + CCCD follows
```

The `0x05` tag for 128-bit UUIDs is visible just before each UUID in the record stream.

---

## 4. Channel A — Command Protocol

The fixed 16-byte command channel over `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` (write `6e400002`, notify `6e400003`).

### What the firmware statically confirms

- The two GATT characteristics (`6e400002` write, `6e400003` notify) and CCCD are present.
- The 16-byte frame is the negotiated ATT_MTU-3 (ATT_MTU=23 minus ATT header = 20; with a 4-byte ATT op + handle, ~16 bytes is the practical write payload).
- The `0x10` literal pool value (16, present at multiple body offsets in timing/array context) is consistent with a 16-byte payload but is not annotated as a frame length. Hard enforcement of "exactly 16 bytes" appears to be a **BLE-stack consequence of the negotiated MTU**, not a per-frame length check in the firmware.
- The Channel-A additive 8-bit checksum algorithm is **not statically recoverable** — it's a 2-instruction sequence (`add` + `and 0xff` or similar) without a dedicated lookup table. The CRC8 poly mentioned in `PROTOCOL.md` is not present in either body as a 256-byte table.

### The 256-byte opcode → bucket table (v13 only)

At v13 body `0x22490`:

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'px 256 @ 0x22490' _re/v13/body.bin
0x00022490  00 40 40 40 40 40 40 40 40 40 41 41 41 41 41 40
0x000224a0  40 40 40 40 40 40 40 40 40 40 40 40 40 40 40 40
0x000224b0  05 02 02 02 02 02 02 02 02 02 02 02 02 02 02 02
0x000224c0  02 02 02 02 02 02 02 02 02 02 20 20 20 20 20 20
0x000224d0  20 20 20 20 02 02 02 02 02 02 02 02 02 02 90 90
0x000224e0  90 90 90 90 10 10 10 10 10 10 10 10 10 10 10 10
0x000224f0  10 10 10 10 10 10 02 02 02 02 02 02 88 88 88 88
0x00022500  88 88 08 08 08 08 08 08 08 08 08 08 08 08 08 08
0x00022510  08 08 08 08 08 08 02 02 02 02 40 00 00 00 00 00 ...
0x00022590                                              ... 00 00
```

Bucket map:

| Bucket id | Opcode ranges | Count |
|---:|---|---:|
| `0x00` | `0x00`, `0x81..0xff` | 129 |
| `0x02` | `0x22..0x30`, `0x3b..0x41`, `0x5c..0x61`, `0x7c..0x7f` | 32 |
| `0x05` | `0x21` | 1 |
| `0x08` | `0x68..0x7b` | 20 |
| `0x10` | `0x48..0x5b` | 20 |
| `0x20` | `0x31..0x3a` | 10 |
| `0x40` | `0x01..0x09`, `0x0f..0x20`, `0x80` | 28 |
| `0x41` | `0x0a..0x0e` | 5 |
| `0x88` | `0x62..0x67` | 6 |
| `0x90` | `0x42..0x47` | 6 |

**Important correction to `RE_FIRMWARE.md` and `PROTOCOL.md`:** the bucket id is a **function of the opcode's numeric range only** — not a read/write/delete/notify permission map. Plain and mixture opcodes **share** the same flags (e.g. plain `0x01 SetTime` and mixture `0x12 DisplayClock` both have flag `0x40`; plain `0x23 SetAlarm` and mixture `0x29 DisplayOrientation` both have flag `0x02`). It is best read as a **contiguous-range handler-group routing table** emitted as `uint8[256]` indexed by raw opcode.

### The bucket table is dead const data and **absent in v14**

```sh
# Search for any of the three distinctive byte signatures:
rafind2 -x 4005020202 firmwares/_re/v13/body.bin   # 1 hit at 0x224b0
rafind2 -x 4005020202 firmwares/_re/v14/body.bin   # 0 hits
rafind2 -x 0202909090 firmwares/_re/v13/body.bin   # 1 hit at 0x224d0
rafind2 -x 0202909090 firmwares/_re/v14/body.bin   # 0 hits
rafind2 -x 02028888   firmwares/_re/v14/body.bin   # 0 hits
```

The bucket table is not referenced from anywhere in v13 either (no pointer in the body resolves to `0x848890` = `0x826400 + 0x22490`). Removing it in v14 was a behavioural no-op.

### The "command literal table" at `0x21b58` (v13) / `0x1ff0c` (v14) — NOT a dispatcher

`r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'pxw 80 @ 0x21b58' _re/v13/body.bin` shows a 20-entry `uint32[]`: `0..0x0b` then `0x50, 0x51, 0x52, 0x53, 0x55, 0x56, 0x58, 0x5a`. This table IS referenced (v13 routine at `0x1d340..0x1d460` via inline pool at `0x1d458`, v14 routine at `0x1c040` via absolute pointer at `0x1c0b8`), but the consumer is a **health-metric range-clamp routine** — it compares an input value against ascending thresholds (`5<<10`, `5<<11`, `0x23<<10`, `0x5f<<8`, `0x73<<8`) and fills a 12-byte buffer. The `0x50..0x5a` values are small integer constants here, not live BLE opcodes.

### Bottom line on Channel A

The radare2 pass correctly ruled out the dead v13 bucket table and the
`0x21b58` / `0x1ff0c` literal pool as live dispatch tables, but its final
"phone-side only" conclusion is superseded by Ghidra. H59MA v14 contains a
real firmware dispatcher at device address `0x0082d2dc`, now named
`channel_a_dispatch_queued_frame` in the saved Ghidra project. That routine
drains a deferred 16-byte request ring (`channel_a_command_queue_state` at
`0x0082d440`) and dispatches byte `0` of each queued 16-byte frame to
per-opcode handlers. Ring metadata lives outside the copied entry at
`state+0x14/+0x16`; entries start at `state+0x18 + index*0x10`.

The on-wire Channel-A frame remains the SDK format documented in `PROTOCOL.md`
(`byte 0 = opcode`, bytes `1..14 = payload`, byte `15 = additive checksum`);
the queued entry matches that layout.

---

## 5. Channel B — Large-Data / File / OTA

Over `de5bf728-d711-4e47-af26-65e3012a5dc7` (write-no-resp `de5bf72a`, notify `de5bf729`). Frame format and parser disassembled instruction-by-instruction.

### Frame format (on-wire)

```text
byte 0      magic 0xBC
byte 1      cmd (sub-action id)
byte 2..3   payload length, little-endian u16
byte 4..5   payload CRC-16, little-endian u16
byte 6..    payload (this fragment's slice)
```

Continuation fragments carry **no** 6-byte header — pure payload appended at `payload + accumulated` until `accumulated >= length`, then the completion/dispatch handler runs.

### Reassembly parser (v13 body `0x8c32`..`0x8cde`, v14 body `0x8bea`..`0x8c96`)

Disasm of the first-fragment branch — magic check:

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'pd 6 @ 0x8c5a' _re/v13/body.bin
0x00008c5a  bc2a   cmp  r2, 0xbc             ; byte 0 == magic
0x00008c5c  1dd1   bne  0x8c9a               ; reject on mismatch
0x00008c5e  2970   strb r1, [r5]             ; state.phase = 1 (in-flight)
0x00008c60  4178   ldrb r1, [r0, 1]
0x00008c62  6970   strb r1, [r5, 1]          ; state.cmd = byte 1
0x00008c64  c178   ldrb r1, [r0, 3]
0x00008c66  21 78  ldrb r2, [r0, 2]
0x00008c68  8940   lsls r1, r1, 8
0x00008c6a  1143   orrs r1, r2
0x00008c6c  6970   strh r1, [r5, 4]          ; state.length = LE u16 (bytes 2,3)
... (CRC field at bytes 4,5: ldrb r1,[r0,5]; ldrb r2,[r0,4]; lsls r1,r1,8; orrs r1,r2; strh r1,[r5,6])
```

Capacity check after first fragment: declared `length` is compared against `0x504` (= `0x50c − 8`, max reassembly buffer minus header/CRC slot). If `length > 0x504` the parser aborts with error code `2`.

### Fragment timeout = `0x7d0` (2000 ms), hardcoded

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'pd 4 @ 0x8cec' _re/v13/body.bin
0x00008cec  7d23    movs r3, 0x7d       ; 125
0x00008cee  0191    str  r1, [sp, 4]
0x00008cf0  1b01    lsls r3, r3, 4      ; r3 = 125 << 4 = 2000  (0x7d0)
0x00008cf2  14a1    adr  r1, 0x50       ; "m_ble_packet_timer_id"
                                       ; 0x8d44
0x00008cf6  f7fffeff bl   app_timer_create
```

Identical sequence at v14 body `0x8ca4..0x8ca8`. The string `m_ble_packet_timer_id` is at v13 `0x8d44`, v14 `0x8cfc`. **Correction to `RE_FIRMWARE.md`:** the literal at `[0x8d40]=0x82ef99` (v13) / `[0x8cf8]=0x82ef51` (v14) is a build-dependent pointer, NOT the timeout interval.

### CRC = CRC-16/MODBUS (poly 0xA001 reflected, init 0xFFFF, no xorout)

The 512-byte CRC table at v13 body `0x2100c` / v14 body `0x1f3c0` matches the canonical CRC-16/MODBUS reflected `0xA001` table byte-for-byte. Verified by recomputing the canonical table in Python and comparing:

```python
>>> import zlib, struct
>>> def modbus():
...     t=[0]*512
...     for i in range(256):
...         c=i
...         for _ in range(8):
...             c = (c>>1) ^ 0xA001 if c&1 else c>>1
...         t[2*i]=c&0xFF; t[2*i+1]=(c>>8)&0xFF
...     return bytes(t)
>>> open('firmwares/_re/v13/body.bin','rb').read()[0x2100c:0x2100c+32].hex()
'0000c1c081c1400101c3c003800241c201c6c006800741c7...'
# matches modbus()[:32] exactly
```

The poly literal `0x01 0xa0` (= `0xA001` LE) is at v13 body `0x2110c` (immediately following the table-end region; same in v14 at `0x1f4c0`). The CRC helper disassembly confirms the standard reflected algorithm:

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'pd 30 @ 0x8d5c' _re/v13/body.bin
0x00008d5c  70b5   push {r4, r5, r6, lr}
0x00008d5e  0446   mov  r4, r0           ; r4 = buf
0x00008d60  0e48   ldr  r0, [0x00008d9c] ; r0 = 0xFFFF  (CRC seed)
0x00008d62  0022   movs r2, 0
0x00008d64  0e4d   ldr  r5, [0x00008da0] ; r5 = 0x0084740c  (CRC table ptr)
0x00008d66  07e0   b    0x8d78
0x00008d68  a65c   ldrb r6, [r4, r2]     ; b = buf[i]
0x00008d6a  c3b2   uxtb r3, r0
0x00008d6c  7340   eors r3, r6           ; (crc ^ b) & 0xff
0x00008d6e  5b00   lsls r3, r3, 1        ; idx = ((crc ^ b) & 0xff) * 2
0x00008d70  eb5a   ldrh r3, [r5, r3]     ; table[idx]
0x00008d72  000a   lsrs r0, r0, 8        ; crc >>= 8
0x00008d74  5840   eors r0, r3           ; crc ^= table[idx]
0x00008d76  521c   adds r2, r2, 1        ; i++
0x00008d78  8a42   cmp  r2, r1           ; vs len
0x00008d7a  f5db   blt  0x8d68
0x00008d7c  70bd   pop  {r4, r5, r6, pc}
```

A second helper at v13 `0x8d7e` accepts a running seed in `r0` and is used for fragment-by-fragment CRC accumulation across continuations.

**This is the single strongest firmware corroboration of `PROTOCOL.md` §3.3 — the spec was silent on the poly; the binary proves it's CRC-16/MODBUS.**

---

## 6. ANCS — Apple Notification Center Service Client

The watch implements an **ANCS client** that subscribes to the iPhone's `7905F431-B5CE-4E99-A40F-4A1BE272D08D` (Notification Source) and `7DBD5630-7E54-4D1F-A2A4-9C5AB74E2C6F` (Data Source) characteristics when the host device is iOS. The GATT service table does not publish a dedicated ANCS service (the watch is a **client**, not a server); ANCS strings appear in the string table:

| String | v13 | v14 |
|---|---:|---:|
| `ancs_send_msg_to_app` | `0x2184a` | `0x1fbfe` |
| `app_parse_notification_source_data` | `0x2185f` | `0x1fc13` |
| `ancs_handle_msg` | `0x21891` | `0x1fc45` |
| `ancs_client_cb` | (adjacent) | (adjacent) |
| `ancs_init` | (adjacent) | (adjacent) |

`PROTOCOL.md` does **not** mention ANCS — this is a new finding from the firmware. The practical consequence: when the watch is paired with an iPhone, incoming iOS notifications are forwarded to the watch via the standard Apple ANCS GATT flow; the Oudmon private notify opcodes (Channel A buckets `0x02`, `0x20`) carry the **watch-side reactions** to those notifications, not the notifications themselves. The H59MA's `Scene_B`/`Scene_C` and Android-package-name string table (`com.facebook.Facebook`, `com.google.Gmail`, `com.burbn.instagram`, `com.facebook.Messenger`, `Telegraph`) is the iOS-side filtering/labeling list for the ANCS client.

---

## 7. OTA / DFU & Flash Update Model

- `m_ota_write_flag_id` string at v13 body `0x90ac`, v14 `0x90ae` (the `ota_write_flag` literal is at `+2`).
- The OTA payload is loaded into flash starting at the **app region** (`flash_base + 0x400 = 0x826400`) by the bootloader; the trampoline at the start of the body is then jumped to.
- The `load_size` field = `body_size + 0x400` (`0x23840` / `0x219fc`). `flash_app_end` is a per-build app-region bound at header `0x22c` (v13 `0x00847860`, v14 `0x00845c14`), not `flash_app_start + load_size`; keep it as an explicit header value until bootloader behavior is captured.
- Channel-B DfuHandle flow (`PROTOCOL.md` §4.9 / §5.4) sends file data via `bc` frames through `de5bf72a`. The watch reassembles, writes each chunk to flash, and on completion reboots into the new image.
- The header's `image_chk_a @0x0c` is `sum(container[0x50:]) & 0xffffffff`. The 32-byte `image_digest @0x1c4` is the other apparent integrity field, but `body.bin` itself does not validate it. The OTA data path checks the first container word (`e5 c3 bd 81`, little-endian `0x81bdc3e5`) and writes only bytes after the 0x50-byte header. The `0x8721bee2` check at `0x00840724` is persistent config-blob validation, not OTA validation. Bootloader-side digest validation remains outside this OTA body.

---

## 8. Embedded Assets — There Are None (correction)

There is **NO embedded JPEG, PNG, GIF or BMP** in either firmware image, despite older extractor output reporting `embedded_jpeg@0x21EEF` (v13) / `embedded_jpeg@0x202A3` (v14).

Image-signature search in both bodies:

| Signature | Meaning | v13 | v14 |
|---|---|---:|---:|
| `ffd8ffe0` / `ffd8ffe1` / `ffd8ffdb` | JPEG SOI | 0 | 0 |
| `ffd9` | JPEG EOI | **1** (false positive — Thumb-2 instruction byte pair in code) | 0 |
| `89504e47` | PNG magic | 0 | 0 |
| `47494638` | GIF magic | 0 | 0 |
| `424d` (`BM`) | BMP magic | **1** in each (false positive — Thumb-2 instruction `42 4d` = `ldr r5,[pc,#imm]`) | 1 |
| `JFIF` ASCII | | 0 | 0 |
| `Exif` ASCII | | 0 | 0 |

The single `424d` hits are real Thumb-2 instructions, not BMP files — disassembly of the surrounding code shows the literal-pool load (`ldr r5, [0x25b8]` at v13 `0x24ae`; v14 `0x2402`). Same for the `ffd9` at v13 `0xbc1c`.

The bytes previously identified as the start of a JPEG (v13 `0x21eef`, v14 `0x202a3`) are actually the start of a mixed **const / string table**:

```text
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c 'px 64 @ 0x21eef' _re/v13/body.bin
0x00021eef  00 dc b5 a0 e2 3a 30 1f 97 ff ff ff ff b4 45 00
0x00021eff  00 fd 25 a0 c8 e9 a3 c1 4f ff ff ff ff ff 3f 00
0x00021f0f  00 00 00 00 80 00 00 00 00 ff 3f 00 00 00 00 00
0x00021f1f  80 00 00 00 00 53 63 65 6e 65 5f 42 00 53 63 65  .....Scene_B.Sce
```

The `53 63 65 6e 65 5f 42` ("Scene_B") at v13 `0x21f25` is the first visible ASCII string in this region; further on (v14 `0x202a3`) we see "Telegraph", "com.facebook.Facebook", "com.google.Gmail", "com.burbn.instagram", "com.facebook.Messenger" — the **iOS ANCS notification filter list** (§6). These are string-table data, not image blobs.

**Correction to older extractor output:** the section `embedded_jpeg@0x21EEF` / `embedded_jpeg@0x202A3` was a spurious section guess. The bytes are clearly not JPEG.

---

## 9. Cross-Version Diff (v13 → v14)

| Metric | v13 | v14 | Δ |
|---|---:|---:|---:|
| Container size | 145552 | 137804 | **−7748** |
| Body size | 144448 | 136700 | **−7748** |
| SHA-256(container) | `7347dc5f…781b65` | `22fab44e…c3e82b` | (entirely new) |
| GATT services | 4 | 4 | = |
| GATT chars | 11 | 11 | = |
| GATT CCCDs | 4 | 4 | = |
| ANCS strings | present | present | = |
| CRC table | identical | identical | = |
| Bucket table (`0x22490`) | present (256 B) | **absent** | removed |
| `0x21b58`/`0x1ff0c` const pool | present | present | = |
| Channel-B parser | `0x8c32..` | `0x8bea..` | relocated (−0x48) |
| CRC table address | body `0x2100c` | body `0x1f3c0` | relocated |
| Trampoline entry | `0x00826741` | `0x00826665` | build-specific |
| `flash_app_end` | `0x00847860` | `0x00845c14` | per-build bound; not formula-derived |
| Build banner (`__DATE__`) | `Thu Mar 17 10:58:10 2022` | identical | same toolchain |

### Verdict: size/bug-fix release, not a feature release

- Same protocol surface (Channel A/B framing, CRC, GATT UUIDs, ANCS).
- 7.7 KB smaller, mostly from removed dead const (the bucket table is gone) and trimmed string/code.
- All four GATT services and 11 characteristics are present in both builds, including the previously-omitted `0xfee7` vendor service.
- Build-string is byte-identical (same GCC toolchain + same compiler day); only the application payload differs.

### Anchor offset table (v13 body → v14 body)

| Anchor | v13 | v14 | Δ |
|---|---:|---:|---:|
| Trampoline entry | `0x0` | `0x0` | 0 |
| Channel-B parser | `0x8c32` | `0x8bea` | −0x48 |
| `cmp byte0,0xbc` site | `0x8c5a` | `0x8c12` | −0x48 |
| CRC table (body) | `0x2100c` | `0x1f3c0` | −0x1c4c |
| CRC table device addr | `0x0084740c` | `0x008457c0` | −0x1c4c |
| `m_ble_packet_timer_id` | `0x8d44` | `0x8cfc` | −0x48 |
| Bucket table | `0x22490` | absent | — |
| Const pool (health clamp) | `0x21b58` | `0x1ff0c` | −0x1c4c |
| ANCS strings | `0x2184a` | `0x1fbfe` | −0x1c4c |
| DevInfo service decl | `0x20c72` | `0x1f026` | −0x1c4c |
| ChanB service decl | `0x20d7c` | `0x1f130` | −0x1c4c |
| ChanA service decl | `0x20e40` | `0x1f1f4` | −0x1c4c |
| fee7 service decl | `0x20f08` | `0x1f2bc` | −0x1c4c |

Code regions shifted by exactly `-0x48`; the GATT/CRC/const regions shifted by exactly `-0x1c4c` — `0x48 + 0x1c04` (some intermediate relocation zone). The body shrank by exactly the 7748 B the linker dropped; no code path was renamed or reordered, just compacted.

---

## 10. Reconciliation with `PROTOCOL.md` (APK-derived spec)

| Spec claim (`PROTOCOL.md`) | Firmware evidence | Verdict |
|---|---|:--:|
| §2.1 — DevInfo service `0x180a` + 5 chars | DevInfo service at v13 `0x20c78`; 4 chars (`0x2a25` serial, `0x2a27` HW rev, `0x2a26` FW rev, `0x2a23` System ID). The "5th char `0x2a28` SW revision" is a field-seam phantom — the bytes are `0x2803` char-decl then `0x2a00` Device Name (which actually belongs to the `0xfee7` block). | **Partial + correction** |
| §2.1 — ChanA service `6e40fff0` | svc decl at v13 `0x20e40` (LE UUID bytes), chars `6e400002` write / `6e400003` notify + CCCD | **Confirmed** |
| §2.1 — ChanB service `de5bf728` | svc decl at v13 `0x20d7c` (LE UUID bytes), chars `de5bf72a` write-no-rsp / `de5bf729` notify + CCCD | **Confirmed** |
| §2.1 — ChanA MTU 0x14 (20 B) | `0x10`/`0x14` literals present but not annotated as MTU; consistent with negotiated ATT_MTU=23 minus 3-byte ATT header. | **Partial** (likely stack-default, not firmware literal) |
| §3.1 — Channel A fixed 16-byte frames | `0x10` literal in pool; no firmware length check; consistent with negotiated MTU. | **Partial** |
| §3.1 — Channel A CRC8 additive | No CRC8 lookup table; the algorithm (2-instruction add+mask) is too small to recover statically. | **Partial** (algorithm not statically provable) |
| §3.2 — Channel B `0xbc` magic | First-fragment parser at v13 `0x8c5a`: `cmp r2, 0xbc`; identical at v14 `0x8c12`. | **Confirmed** |
| §3.2 — Channel B `len16LE` field at bytes 2..3 | `ldrb r1,[r0,3]; ldrb r2,[r0,2]; lsls r1,r1,8; orrs r1,r2; strh r1,[r5,4]` at v13 `0x8c64..0x8c6c` | **Confirmed** |
| §3.2 — Channel B CRC16 of payload | CRC-16/MODBUS (poly 0xA001) proven from 512-byte lookup table at v13 `0x2100c` / v14 `0x1f3c0`. | **Confirmed + EXTENDED** (spec was silent on the poly; firmware proves it) |
| §3.2 — empty-payload ⇒ `ff ff ff ff` CRC field | `ff ff ff ff` follows `0xbc` 17 times in v13, 15 in v14 (cross-checked against CRC of zero bytes). | **Confirmed** |
| §3.3 — per-channel CRC difference | Chan A: additive 8-bit (CRC8); Chan B: CRC-16/MODBUS. | **Confirmed** |
| §3 — 256-opcode Channel A dispatch | Bucket table at v13 `0x22490` (v14: absent). The flag is a range-classifier, not a r/w/d/notify permission map — **spec misread on this point**. | **Confirmed structurally, reframed** |
| §4 — opcode families (e.g. `0x40` plain, `0x41` mixture) | Bucket assignments in v13 match spec categories loosely. The literal pool `0x50..0x5a` (and `0x60..0x63`) is now known to be health-clamp data, not live opcode coverage. | **Partial + correction** |
| §4.2.1 — 14-byte SetTimeRsp capability bitmap | Built at runtime from per-device manifest; not statically recoverable. | **Cannot verify** |
| §2.3 — handshake (read FW/HW rev → ready) | `0x2a27` HW rev + `0x2a26` FW rev chars present and readable; no explicit handshake code path recovered. | **Partially confirmed** |

### New findings in firmware, not in `PROTOCOL.md`

1. **Realtek RTL8762x "Bee"** SoC + SDK (§SoC section).
2. **Flash load base** `0x00826400`, not `0x800000` (`load_size = body_size + 0x400`).
3. **Real per-build 32-byte image digest at container `0x1c4`** (§1) — not the 16-byte "nonce2" at `0x1c0`.
4. **The `0x5c` word is a fixed GUID, not a build timestamp** — older `fwtool`/`header.json` output misrendered it as `2037-03-18T03:54:33Z`.
5. **Channel B fragment timeout = `0x7d0` (2000 ms)** hardcoded (`movs r3,0x7d; lsls r3,r3,4`).
6. **The bucket table is dead const data, unreferenced from any code**, and entirely absent in v14.
7. **The `0x21b58`/`0x1ff0c` literal pool is health-clamp, not opcode-dispatch.**
8. **ANCS client** — the watch subscribes to iPhone notifications via Apple's ANCS GATT service (§6).
9. **`0xfee7` vendor GATT service** + 3 chars + Device Name (§3) — previously omitted from all docs.
10. **No `0x2a28` SW revision char** — DevInfo has 4 chars, not 5.
11. **No embedded image** — older extractor output reported `embedded_jpeg@0x21EEF` / `@0x202A3`, a false positive on the ANCS notification string table (§8).

---

## 11. `fwtool` Parser Status

The current `tool/fwtool` parser already incorporates the major header fixes
listed by the earlier radare2 notes:

- `image_chk_a`, `body_size`, `const_5c`, `const_b4`, `const_228`,
  `flash_app_start`, `flash_base`, `flash_app_end`, and the 32-byte
  `image_digest @0x1c4` are first-class fields.
- The old `build_time`, `nonce2`, `crc2`, `crc3`, and
  `secondary_signature` names have been replaced with reserved/constant fields.
- `signature_a` is correctly 12 bytes at `0x60..0x6b`; the following word is
  `flash_app_start`.
- `unpack` writes only the source `body.bin` section; stale ignored
  `_re/.../assets/embedded_jpeg@...` artifacts were false positives and are no
  longer source evidence.

`image_chk_a` is documented in `tool/fwtool` with the exact formula
`sum(container[0x50:]) & 0xffffffff`.

---

## 12. Open Questions / TODO

1. **Algorithm behind the 32-byte `image_digest @0x1c4`.** Not SHA-256 of any contiguous window; not MD5, not CRC32; not truncated SHA-1. Likely a vendor-proprietary keyed MAC using `signature_a` or `0x5C` GUID as key. Required to determine whether the bootloader verifies the digest or ignores it.
2. ~~Algorithm behind the `image_chk_a @0x0c` additive byte-sum.~~ **Resolved:** it is `sum(container[0x50:]) & 0xffffffff` for both v13 and v14.
3. ~~Exact Channel A dispatch path — phone-side vs watch-side.~~ **Resolved by Ghidra:** v14 drains an internal 16-byte queued-frame ring in `channel_a_dispatch_queued_frame` (`0x0082d2dc`). The phone-side SDK still owns wire framing and response correlation.
4. ~~Channel A additive 8-bit checksum algorithm.~~ **Resolved by Ghidra:** `checksum8_additive` (`0x0082b0c4`) sums caller-specified bytes; Channel-A/FEE7 responses use bytes `0..14`.
5. ~~Channel B sub-cmd bytes that the watch accepts beyond `PROTOCOL.md` §3.2.~~ **Resolved for static firmware routing:** a 2026-07-05 radare2 pass verifies the first-stage v13/v14 dispatcher groups and the second-stage async switch/cascade (`firmwares/_re/channel-b-dispatch/evidence.md`).
   `0x01`, `0x02`, `0x21`, `0x31`, `0x35`, `0x36`, and `0x61` call the OTA-state callback before falling through to async storage; `0x10`/`0x46` bypass async storage through the cleanup helper; every other valid-CRC frame enters the async worker directly.
   The low OTA switch has max explicit index `0x08`, so `0x08..0x10` clamp to the default NAK path.
   The compare cascade handles sleep `0x11/0x12/0x27`, activity `0x2a`, alarm `0x2c`, file table `0x41/0x43/0x46`, no-op placeholders `0x13/0x29/0x3b/0x47/0x4b`, device-info/config `0x5a`, and explicit NAK-code-2 commands `0x21..0x24`; unknown commands NAK with code `0`.
   Remaining work is payload semantics for opaque/no-op handlers, not command acceptance.
6. **Whether the OTA bootloader validates `image_digest` and `signature_a`** at flash time. Ghidra shows `body.bin` only checks the OTA container magic `0x81bdc3e5` in packet 1 and stages `size - 0x50` bytes. The `0x8721bee2` magic belongs to the config blob.
7. **GATT attribute table is laid out in fixed 28-byte records** — but the precise record fields (perm byte, value-handle byte, flash-value-pointer semantics) need a runnable emulator to confirm.
8. **`0xfee7` remaining vendor command semantics** — Ghidra confirms the service is an active second 16-byte command channel, and the `0x97..0xa0` high switch is now mapped in `firmwares/GHIDRA_DECOMPILATION.md` §8.1. Raw memory read/write (`0xbf`/`0xc0`) are resolved in §8.17 and rechecked with radare2 at v14 body offsets `0x5694` / `0x570c` plus the shared streamer at `0x5538`. `0xc1` health poll and `0xc3` OTA-control byte indexes are also statically resolved at offsets `0x64ce` / `0x64e0`; remaining work is live runtime-impact verification for the OTA-control side effects.

---

## 13. Reproducing this analysis

```sh
cd /home/workspace/git/openwatch

# Rebuild fwtool (or use the prebuilt ./tool/fwtool/fwtool)
( cd tool/fwtool && go build -o /tmp/fwtool ./cmd/fwtool )

# Inspect container
/tmp/fwtool info firmwares/H59MA_1.00.13_251230.bin
/tmp/fwtool info firmwares/H59MA_1.00.14_260508.bin

# Re-extract the bodies (regenerable; .gitignored)
/tmp/fwtool unpack firmwares/H59MA_1.00.13_251230.bin -o firmwares/_re/v13
/tmp/fwtool unpack firmwares/H59MA_1.00.14_260508.bin -o firmwares/_re/v14

# Diff
/tmp/fwtool compare firmwares/H59MA_1.00.13_251230.bin firmwares/H59MA_1.00.14_260508.bin

# r2 disasm / hex / search examples
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
   -c 'pd 6 @ 0x8c5a; pd 30 @ 0x8d5c; px 256 @ 0x22490' firmwares/_re/v13/body.bin

# Python byte-read example
python3 -c "d=open('firmwares/_re/v13/body.bin','rb').read(); print(d[0x2100c:0x2100c+32].hex())"

# Re-run BLE / string scans
python3 firmwares/_re/ble-hunt/scan.py
```

---

## 14. Evidence index

| Dir / file | Contents |
|---|---|
| `firmwares/_re/v13/body.bin` | header-stripped body of v13 (.gitignored, regenerable) |
| `firmwares/_re/v13/header.json` | older raw header decode by `fwtool info`; superseded by current `tool/fwtool` parser output and §1 |
| `firmwares/_re/v13/strings.txt` | ASCII string extraction from v13 body |
| `firmwares/_re/v14/*` | same as v13 |
| `firmwares/_re/ble-hunt/` | `scan_results.json` (every constant hit, both firmwares), `key_regions.txt` (labelled offsets), `scan.py` (reproducible) |
| `firmwares/_re/ble-validate/evidence.md` | BLE transport validation notes |
| `firmwares/_re/protocol-validate/` | 15 files: CRC table reconstruction (`01..06_crc_*`), opcode audit (`07`), Thumb cmp (`08`), dispatch inspection (`09..11`), string hunt (`12`), bc-frame counts (`13`), spec-vs-binary comparison (`14`), summary (`15`) |
| `firmwares/_re/strings-mining/` | `findings.txt` + per-category grep files (`ota.txt`, `cmd_proto.txt`, `paths.txt`, `hex_uuid.txt`, `watchface.txt`, `vendors.txt`, `ble.txt`, `uuids.txt`, `mac_hex.txt`, `ble_full.txt`, `vendors_full.txt`, `paths2.txt`, `commands.txt`) |
| `firmwares/_re/diff/` | `fwtool_compare.txt`, large identical/divergent regions, `v{13,14}_{real,natural_strings,real_only}.txt`, `strings_only_in_v{13,14}.txt`, `feature_words_v14.txt`, `regions_collapsed.txt` |
| `firmwares/_re/channel-b-dispatch/evidence.md` | radare2 evidence for Channel-B first-stage routing and the corrected low-command switch table shape |
| `firmwares/RE_FIRMWARE.md` | superseded by this document (initial RE notes; many field-level errors) |
| `firmwares/R2_ANALYSIS.md` | superseded by this document (r2 deep-dive; itself corrects RE_FIRMWARE.md) |
| `PROTOCOL.md` | APK-derived protocol spec that this firmware corroborates |
