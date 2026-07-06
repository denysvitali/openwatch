# H59MA Firmware — radare2 Deep-Dive Analysis

## 1. Scope & Tooling

This document is the verified, instruction-level reverse-engineering reference for the **Oudmon / H59MA** smartwatch firmware (ARM Cortex-M, raw Thumb-2, no ELF, no symbols). It **verifies and extends** `RE_FIRMWARE.md`; every claim below is backed by an actual radare2 command and its output.

**Tooling:** radare2 6.1.4, raw Thumb mode:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -c '<cmd>' <file>
```

**Images analysed:**

| Image | Container size | Body size (= container − 0x450) | crc32(body) |
|---|---:|---:|---|
| `H59MA_1.00.13_251230.bin` (v13) | `0x23890` (145 552 B) | `0x23440` (144 448 B) | `0x06e82ea6` |
| `H59MA_1.00.14_260508.bin` (v14) | `0x21a4c` | `0x215fc` (136 700 B) | `0xfb997b47` |

> The `crc32(body)` values are listed because they do **not** match the header's `0x0C` integrity word — that field is an additive byte-sum, not a CRC (see Container/Header). Body `.bin` files were carved at `_re/v13/body.bin` and `_re/v14/body.bin`.

**Offset convention (used throughout):**

```text
container_offset = body_offset + 0x450
device_addr      = 0x00826400 + body_offset      (flash load base, both builds)
```

Unless a value is explicitly prefixed `container:`, all offsets are **body** offsets.

---

## 2. Corrections to `RE_FIRMWARE.md` / `header.json`

The prior notes were broadly directionally right but carry a number of concrete factual errors. All of the following are corrected and re-verified in the sections below.

### Header / container (`header.json`)

- **Header fields were never documented at field level.** The 0x450 size was known; the per-field decode lived only in `header.json`, and several of those entries are wrong. A corrected field table is in §3.
- **`unknown32_b` @`0x58` is `body_size`** — the exact byte length of `body.bin` (= container − 0x450). Not "unknown".
- **`build_time_unix` @`0x5c` is NOT a timestamp.** The word `0x7e6b4cf9` is **byte-identical** across two builds 5 months apart; it is a fixed constant. (The JSON's "2037-03-18" rendering is nonsensical.)
- **`signature_a` @`0x60` is 12 bytes, not 16** (`0x60`–`0x6b`). The trailing 4 bytes (`00 64 82 00`) are a separate field: `flash_app_start = 0x00826400`.
- **`nonce_or_key` @`0x70` is not a key/nonce.** It is the flash-pointer cluster: `0x6c`/`0x70 = 0x00826400`, `0x74 = 0`, `0x78 = 0x00826000` (flash_base).
- **The real per-build digest is 32 bytes at `0x1c4`** (consistent with SHA-256), not 28, and not the 16-byte `nonce2 @0x448` the JSON claims. The JSON read it 4 bytes early (at `0x1c0`, absorbing 4 zero bytes) and truncated to 16. (This 28→32 size fix corrects the `container` section's own earlier "28-byte" wording as well.)
- **`secondary_signature` @`0x440` does not exist** — `0x440`–`0x44f` is an all-`0xFF` erased-flash marker. The real signature is `image_digest` @`0x1c4`.
- **`crc2` @`0x220` and `crc3` @`0x340` are not CRC slots.** `0x220` is zero padding; `0x330`/`0x440` are `0xFF` erase markers. The constant fields actually present and previously undocumented are **`const_b4 = 0x1201a39e` @`0xb4`** and **`const_228 = 0x0e85d101` @`0x228`**, plus the varying **`flash_app_end` @`0x22c`**.
- **`unknown32a` @`0xc` is an image checksum/hash word** (high byte always `0x00`, varies per build: `0x00ce90ee` v13 / `0x00c43671` v14), not "always 0x00CE90EE".
- **Container `0x54` (`0x27930981`) and the `0x5C` GUID (`7e6b4cf9-c511-11eb-8282-f74a0c0cef5b`) are byte-identical across both builds** — reinforcing that the "build_time" word is not a real timestamp.

### Memory map / SoC

- **Load base was never stated.** The OTA body loads at flash base **`0x00826400`** (both builds), proven by the CRC-table literal `[body 0x8da0] = 0x0084740c = 0x826400 + 0x2100c`. The brief's "flash base ~0x800000" identifies the right region, but the body image itself starts at `0x826400`.
- **The implied base `~0x826740` (from the trampoline word `0x00826741`) is off by `0x340`** for section addressing. `0x826741` is the *thumb entry*, not the section base. The confirmed base is `0x826400`; using `0x826740` makes all pointer searches miss.
- **The trampoline word @`0x4` differs per build** (v13 `0x00826741`, v14 `0x00826665`) — it is build-specific. The shared/stable flash addresses live in the container header (`0x00826400` @container `0x6C`, `0x00826000` @container `0x74`).
- **SoC/RTOS was never identified.** It is the **Realtek RTL8762x "Bee" BLE stack** (evidence: `le_vendor_*`, `gatts_add_client`, `dlps` / "allowed enter dlps", `FMC`, `app_main_task`) — not Nordic SoftDevice, Telink, or a generic stack.
- **Prior mining's `BEE2` marker is a FALSE POSITIVE** — it matched the hex *offset* column `0x0001BEE2`, whose string value is the unrelated `hFAZ`. Not a stack identifier.
- **There is NO Cortex-M vector table inside the OTA body** (zero candidates on a full scan). The vector table / SP / reset vectors live in the excluded lower-flash boot region, reached only via the trampoline.
- **The SRAM aperture was omitted:** `0x20000000` … `~0x200fe358` (~1 MB), referenced by 877 (v13) / 845 (v14) RAM pointers.

### Channel B

- **The timer literal is not the timeout interval.** `[0x8d40]=0x82ef99` (v13) / `[0x8cf8]=0x82ef51` (v14) is a build-dependent pointer. The actual fragment-timeout interval is the hardcoded constant **`0x7d0` (2000)**, built by `movs r3,0x7d; lsls r3,r3,4` at v13 `0x8cec`–`0x8cf0` / v14 `0x8ca4`–`0x8ca8`.

### Channel A

- **The opcode bucket table @`0x22490` is NOT a read/write/delete/notify map.** The flag is a function of the opcode's numeric range only; mixture and plain commands share flags (e.g. `0x40` holds plain `0x01 SetTime` and mixture `0x12 DisplayClock`; `0x02` holds plain `0x23 SetAlarm` and mixture `0x29 DisplayOrientation`).
- **The v14 bucket table is entirely ABSENT** (not "repacked"). All three distinctive byte signatures return zero hits in v14 (`/x 4005020202`, `/x 0202909090`, `/x 02028888`).
- **The bucket-table tail `0x81..0xff` is zero-fill padding**, not a populated range; the last real entry is opcode `0x80 = 0x40`. The table is never referenced by code.
- **`0x21b58`/`0x1ff0c` is not a "command literal table" for Channel-A dispatch.** It is referenced only by a health-metric range-clamp routine (v13 `0x1d340` via inline pool at `0x1d458`; v14 `0x1c040` via absolute pointer at `0x1c0b8 → 0x84630c`). The `0x50..0x5a` values there are reused as small integer constants, not live BLE opcodes.
- **There IS a firmware Channel-A dispatcher in v14.** Ghidra decompilation identifies `FUN_0082d2dc` at `0x0082d2dc`: it drains a 16-byte frame ring buffer, strips/processes the opcode at offset `2`, and dispatches to per-opcode handlers. The earlier conclusion that "Channel-A dispatch is phone-side only" was based on the dead bucket table and is therefore incorrect. See `firmwares/GHIDRA_DECOMPILATION.md` §3 for the opcode map.

### BLE GATT

- **A 4th GATT service was omitted:** vendor service `0x0000fee7` (svc-UUID v13 `0x20f08` / v14 `0x1f2bc`) with characteristics `0xfea1` write+CCCD, `0xfec9` read, `0xfea2` notify+CCCD, and a `0x2a00` Device Name value. Both bodies contain it (4 services / 11 char decls / 4 CCCDs).
- **The claimed "SW revision char `0x2a28`" does NOT exist.** The bytes at v13 `0x20faf` / v14 `0x1f363` are a char-declaration `0x2803` immediately followed by value UUID `0x2a00` (Device Name); the `0x2a28` "hit" straddles the `0x2803`/`0x2a00` field seam. DevInfo has **4** chars (`0x2a25` serial, `0x2a27` HW rev, `0x2a26` FW rev, `0x2a23` System ID), not 5.
- **Several GATT offsets in the notes are off by a few bytes** vs the actual UUID byte positions. Use the UUID-byte offsets given in §7 for precise patching. Notably: Device Info service UUID bytes start at `0x20c78`/`0x1f02c` (the `0x20c72`/`0x1f026` value is the record/attr start); Channel A write v14 actual `0x1f23e` (not `0x1f238`); Channel A notify v14 `0x1f276` (not `0x1f274`); Channel B write `0x20dc6`/`0x1f17a` (not `0x20dca`/`0x1f17e`); Channel B notify v13 `0x20dfe` (not `0x20dfc`).
- **The attribute-table record structure was undocumented:** a fixed-stride array of `0x1c` (28)-byte records (`0x38` per full characteristic), half-word aligned, with 16-bit type markers `0x2800`/`0x2803`/`0x2902`, inline 128-bit UUIDs prefixed by a `0x05` type tag, and `0x0084xxxx` flash value pointers.

### Strings / assets

- **There is NO embedded JPEG** (the layout-table row at v13 `0x21eef` / v14 `0x202a3` is wrong). Proper JFIF/Exif SOI searches (`ffd8ffe0/e1/db`) and JFIF/Exif string searches return no hits; v14 has zero `ffd9` EOI bytes; the cited offsets land in 32-bit const-table data, not pixels. No PNG/GIF/BMP either.
- **What is actually at v14 `0x202a3`** is the iOS ANCS notification app-package string table (`Telegraph`, `com.facebook.Facebook`, `com.google.Gmail`, …). The region around v13 `0x21eef`/v14 `0x202a3` is mixed const data including `Scene_B`/`Scene_C` markers and the ANCS list — identical in both builds, not an image asset. The "6561 vs 6057" JPEG figures do not correspond to any locatable image; the size reduction is debug-string/code removal.

---

## 3. Container / Header — the 0x450 prelude *(unverified)*

> *This dimension is marked unverified only because the independent verifier caught and fixed the 28→32-byte `image_digest` size error; all other field-level claims reproduced exactly.*

Every H59MA image is a `0x450`-byte container header followed immediately by the raw Thumb-2 body (`container_offset = body_offset + 0x450`). Bytes were dumped directly from the container files:

```sh
r2 -2 -q -a arm -b 16 -e scr.color=0 -c 'px 0x460 @ 0x0' H59MA_1.00.13_251230.bin
r2 -2 -q -a arm -b 16 -e scr.color=0 -c 'px 0x460 @ 0x0' H59MA_1.00.14_260508.bin
```

```text
0x00000000  e5c3 bd81 4038 0200 4038 0200 ee90 ce00  ....@8..@8......
0x00000050  0c00 8109 9327 0000 4034 0200 f94c 6b7e  .....'..@4...Lk~
0x00000060  11c5 eb11 8282 f74a 0c0c ef5b 0064 8200  .......J...[.d..
0x00000070  0064 8200 0000 0000 0060 8200 0000 0000  .d.......`......
```

### Corrected header field table

All offsets are **container** offsets. "C" = constant across both builds, "V" = varies. LE = little-endian u32.

| Off | Size | Field | v13 | v14 | C/V | Meaning |
|----:|----:|---|---|---|:--:|---|
| `0x00` | 4 | `magic` | `e5c3bd81` | `e5c3bd81` | C | File magic `E5 C3 BD 81`. |
| `0x04` | 4 | `load_size` | `0x00023840` | `0x000219fc` | V | = `body_size` + `0x400`. Duplicated at `0x08`. |
| `0x08` | 4 | `firmware_size` | `0x00023840` | `0x000219fc` | V | Always equal to `load_size`. |
| `0x0c` | 4 | `image_crc/hash_a` | `0x00ce90ee` | `0x00c43671` | V | 24-bit additive checksum/hash (high byte always `0x00`); **not** a CRC32, size, or time. |
| `0x10` | 24 | `version_string` | `H59MA_1.00.13_251230` | `H59MA_1.00.14_260508` | V | ASCII, NUL-padded. |
| `0x30` | 16 | `hw_id` | `H59MA_V1.0` | `H59MA_V1.0` | C | ASCII, NUL-padded. |
| `0x40` | 16 | (zero pad) | `00…` | `00…` | C | Reserved. |
| `0x50` | 4 | `flags` | `0x0981000c` | `0x0981000c` | C | Build/feature flags (disk `0c 00 81 09`). |
| `0x54` | 4 | `sdk_id` | `0x00002793` | `0x00002793` | C | SDK/chip id (disk `93 27 00 00`). |
| `0x58` | 4 | **`body_size`** | `0x00023440` | `0x000215fc` | V | **Exact size of `body.bin`** = container − `0x450`. (Was `unknown32_b`.) |
| `0x5c` | 4 | `const_5c` | `0x7e6b4cf9` | `0x7e6b4cf9` | C | **Identical in both builds → NOT a timestamp.** First u32 of the `0x5C` GUID. |
| `0x60` | 12 | `signature_a` | `11c5eb11 8282f74a 0c0cef5b` | identical | C | 12-byte constant blob (`0x60`–`0x6b`). |
| `0x6c` | 4 | `flash_app_start` | `0x00826400` | `0x00826400` | C | App region start (= `flash_base` + `0x400`). |
| `0x70` | 4 | `flash_app_start2` | `0x00826400` | `0x00826400` | C | Duplicate of `0x6c`. |
| `0x74` | 4 | (zero) | `0x00000000` | `0x00000000` | C | Reserved. |
| `0x78` | 4 | `flash_base` | `0x00826000` | `0x00826000` | C | Flash region base (= `0x6c` − `0x400`). |
| `0x7c` | 56 | (zero pad) | `00…` | `00…` | C | Reserved. |
| `0xb0` | 4 | `board_marker` | `0x00001041` | `0x00001041` | C | Disk `41 10 00 00`. |
| `0xb4` | 4 | `const_b4` | `0x1201a39e` | `0x1201a39e` | C | **New field, missing from JSON.** Constant. |
| `0xb8` | 8 | `sdk_string` | `sdk#####` | `sdk#####` | C | ASCII `73 64 6b 23 23 23 23 23`. |
| `0xc0`–`0x1bf` | 256 | (zero pad) | `00…` | `00…` | C | Reserved gap. |
| `0x1c0` | 4 | (zero) | `0x00000000` | `0x00000000` | C | Leading zeros of digest slot. |
| `0x1c4` | **32** | **`image_digest`** | `8d50aa22…42178bb1` | `47d3b81a…0d354648` | V | **The real per-build signature/digest.** 32 high-entropy bytes (`0x1c4`–`0x1e3`), consistent with SHA-256; zeros begin at `0x1e4`. |
| `0x1e4`–`0x227` | 68 | (zero pad) | `00…` | `00…` | C | Reserved. |
| `0x228` | 4 | `const_228` | `0x0e85d101` | `0x0e85d101` | C | First word of the linked-runtime tail marker also targeted by `flash_app_end @0x22c`. |
| `0x22c` | 4 | `flash_app_end` | `0x00847860` | `0x00845c14` | V | Per-build pointer into the loaded image. It maps to a unique `0x0e85d101,0x00000001` marker before the linked runtime tail, not to the physical body end. |
| `0x230`–`0x32f` | — | (zero) | `00…` | `00…` | C | Reserved. |
| `0x330` | 16 | `erase_marker` | `ff…ff` | `ff…ff` | C | All-`0xFF`. |
| `0x340`–`0x43f` | — | (zero) | `00…` | `00…` | C | Reserved. |
| `0x440` | 16 | `erase_marker2` | `ff…ff` | `ff…ff` | C | All-`0xFF`. Body trampoline (`48 00 47 00`) begins at `0x450`. |

> The JSON fields `nonce_or_key @0x70`, `nonce2 @0x448`, `crc2 @0x220`, `crc3 @0x340`, and `secondary_signature @0x440` are all **incorrect** — see §2.

### Why `0x5c` is not a build time

`const_5c = 0x7e6b4cf9` is byte-for-byte identical in 1.00.13 and 1.00.14, produced ~5 months apart (`251230` vs `260508`). A real timestamp could not be identical.

```sh
r2 -q -c 'pxw 4 @ 0x5c' H59MA_1.00.13_251230.bin   # 0x7e6b4cf9
r2 -q -c 'pxw 4 @ 0x5c' H59MA_1.00.14_260508.bin   # 0x7e6b4cf9
```

It is the first word of the constant `0x5C` GUID `7e6b4cf9-c511-11eb-8282-f74a0c0cef5b` (RFC-4122 v1, also identical in both builds). Interpreted as LE Unix time it would be 2037-03-18 — another tell.

### The `0x0C` integrity field is an additive sum, not a CRC32

Standard CRC32 of the body does **not** match the `0x0C` word; the value tracks a running byte-sum instead (same top byte, same magnitude):

```text
crc32(v13 body)   = 0x06e82ea6   header@0x0C = 0x00ce90ee   (mismatch)
bytesum(v13 body) = 0x00ce4dd5   bytesum(container[0x60:]) = 0x00ce8cfa
crc32(v14 body)   = 0xfb997b47   header@0x0C = 0x00c43671   (mismatch)
bytesum(v14 body) = 0x00c3f5ef   bytesum(container[0x60:]) = 0x00c431e0
```

The only CRC machinery in the firmware is the CRC-16/MODBUS table (§5); container integrity relies on a plain summation, distinct from the BLE Channel-B payload CRC.

### Size & flash-address arithmetic

```text
body_size (0x58)        = container_size - 0x450      (0x23440 = 0x23890 - 0x450)
load_size/fw_size (0x4) = body_size + 0x400           (0x23840 = 0x23440 + 0x400)
flash_app_start (0x6c)  = flash_base (0x78) + 0x400   (0x826400 = 0x826000 + 0x400)
```

```sh
printf '%x\n' $(stat -c%s H59MA_1.00.13_251230.bin)   # 23890  => -0x450 = 0x23440 == 0x58
printf '%x\n' $(stat -c%s H59MA_1.00.14_260508.bin)   # 21a4c  => -0x450 = 0x215fc == 0x58
```

```sh
r2 -q -c 'pxw 8 @ 0x0' _re/v13/body.bin   # 0x47004800 0x00826741
r2 -q -c 'pxw 8 @ 0x0' _re/v14/body.bin   # 0x47004800 0x00826665
```

### Constant vs varying summary

| Constant across builds | Varying per build |
|---|---|
| `magic`, `hw_id`, `flags 0x0981000c`, `sdk_id 0x2793`, `board_marker 0x1041`, `sdk_string`, `signature_a` (12B), `flash_base/app_start` (`0x826000`/`0x826400`), `const_5c 0x7e6b4cf9`, `const_b4 0x1201a39e`, `const_228 0x0e85d101`, `0x5C` GUID | `load_size`/`firmware_size`, `image_crc/hash_a @0xc`, `version_string`, `body_size @0x58`, `image_digest @0x1c4` (32B), `flash_app_end @0x22c` |

The only genuinely build-specific, high-entropy material is the **32-byte `image_digest` at `0x1c4`**, plus the version string, the size/pointer values, and the `0x0c` checksum word.

### Entropy: body is plain code, not compressed/encrypted

```text
header 0..0x450 : v13 1.384  v14 1.372   (mostly zeros)
body  0x450..end: v13 6.983  v14 6.984   (typical ARM Thumb-2 code + const data)
```

~6.98 bits/byte is squarely plain ARM firmware (packed/encrypted payloads measure ~7.99). Corroborated by directly readable ASCII GATT UUID tables and the CRC-16/MODBUS table. The container is **plaintext code with a metadata/signature header**, not an encrypted blob.

---

## 4. Memory Map, Load Base, Entry & SoC Family

All values are derived from the two `body.bin` files (offsets are **body** offsets).

### Entry trampoline (body offset `0x0`)

Both bodies begin with an identical 4-byte position-independent trampoline, followed by an absolute jump-target word and two `nop` padders:

```text
# r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -c 'pd 6 @ 0' _re/v13/body.bin
0x00000000  0048   ldr r0, [0x00000004]   ; load word @0x4
0x00000002  0047   bx  r0                 ; branch (thumb bit set)
0x00000004  ....   <abs entry target>     ; v13=0x00826741  v14=0x00826665
0x00000008  c046   mov r8, r8             ; nop
0x0000000a  c046   mov r8, r8             ; nop
```

| Field | v13 | v14 |
|---|---|---|
| Trampoline opcodes | `48 00 47 00` | `48 00 47 00` |
| Entry word @`0x4` | `0x00826741` | `0x00826665` |
| Thumb entry address | `0x00826740` | `0x00826664` |

The `ldr/bx` pair reads the absolute entry address from `0x4` and jumps to it (low bit = thumb). The entry word is **not** PC-relative — it is an absolute flash address, which is what lets us back out the load base. Note the word differs per build, so it is *not* a stable flash anchor.

### Flash load base = `0x00826400` (both builds)

Treating each 32-bit LE word in the body as a candidate pointer, the flash-range pointers (`0x0080_0000`–`0x0090_0000`) dominate (v13: 441 such words; the top-byte `0x00` bucket is the single largest at 2932 words). They cluster tightly in `0x82xxxx`–`0x84xxxx`:

```text
# 64KB histogram of 0x008x_xxxx pointers (v13)
0x820000:70  0x830000:128  0x840000:166   (peak region)
```

Voting every (flash-pointer − known-anchor-offset) pair against documented anchors converges, identically for v13 and v14, on **base `0x00826400`**. Decisive confirmation — the Channel-B parser's CRC-table literal resolves exactly:

```text
# pxw 8 @ 0x8da0  _re/v13/body.bin
0x00008da0  0x0084740c ...
# base 0x826400 + CRC-table body offset 0x2100c = 0x84740c  -> MATCH
```

And the entry address lands on a genuine function prologue (not mid-instruction):

```text
v13 @ fileoff 0x340 (0x826740):  10b5  push {r4, lr}
v14 @ fileoff 0x264 (0x826664):  10b5  push {r4, lr}
```

| Quantity | v13 | v14 |
|---|---|---|
| Flash load base | `0x00826400` | `0x00826400` |
| Body span in flash | `0x826400`–`0x849840` | `0x826400`–`0x8479fc` |
| Entry → body file offset | `0x340` | `0x264` |

**Address conversion (final):** `device_addr = 0x826400 + body_offset`; `container_offset = body_offset + 0x450`. E.g. CRC table v13: body `0x2100c` = device `0x84740c` = container `0x2145c`.

> ~354/441 (v13) flash pointers fall inside `[base, base+size)`; the rest point **below** `0x826400` (down to `0x80004c`) and **above** `0x849840` (up to `0x8d0c02`). Those targets are outside this OTA slice — they reference the boot/loader region and stack/patch code the body does not contain. Total flash span referenced is ~`0xd0bb6` (~855 KB), far larger than the ~141 KB (144 KB decimal) body, proving the body is one app slice of a larger flash image.

### No Cortex-M vector table in the body

A full-image scan for a Cortex-M vector table (word0 = initial SP in the `0x2000_0000` SRAM range, followed by ≥8 odd/thumb flash handler addresses) returns **zero** candidates in both bodies. Word0 is the trampoline (`0x47004800`), not an SP. The genuine vector table (SP + reset/NMI/HardFault vectors) lives in the lower flash region (≤`0x826400`) excluded from the OTA payload — consistent with a ROM/patch-bootloader SoC where the app is flashed above a fixed bootloader and reached via the trampoline.

### SRAM region = `0x2000_0000` … `~0x200f_e358`

RAM-range pointers (`0x2000_0000`–`0x2010_0000`) are abundant and contiguous: v13 has 877, v14 has 845, spanning `0x20000000` … `0x200fe358` in both builds. The entry function immediately dereferences RAM state, e.g. `=0x002002c0` (RAM control block) and `=0x002011d0` (RAM slot written with flash ptr `0x8266ef`). This confirms a single ~1 MB SRAM aperture based at `0x2000_0000`.

### SoC / BLE stack = Realtek RTL8762x "Bee"

The string table carries the Realtek BLE SDK's distinctive API surface plus its exclusive **DLPS** power term and **FMC** (Flash Memory Controller):

```text
le_vendor_drop_acl_data     le_vendor_update_conn_param
le_vendor_set_priority      le_power_on / le_msg
gatts_add_client            ancs_handle_msg   (Apple ANCS)
app_main_task               app_send_msg_to_apptask
"allowed enter dlps"        "FMC"   "FmC_h"
```

`DLPS` (Deep Low Power State) and the `le_vendor_*` / `gatts_add_client` naming are unique to the **Realtek RTL8762x ("Bee") BLE SoC SDK** (RTL8762D/E class). This is **not** Nordic SoftDevice (no `sd_*`/`SVC`/`nrf`), **not** Telink (`tlsr`/`blt_`). The flash base around `0x80_0000` and SRAM at `0x2000_0000` match the published RTL8762x map. The earlier `BEE2` "hit" was a false positive on the hex *offset* column `0x0001BEE2` (value: `hFAZ`).

---

## 5. Channel-B Fragment Reassembly Parser & CRC-16/MODBUS

The Channel-B (large-data / OTA) notify-fragment reassembly parser, disassembled instruction-by-instruction at both versions.

| Item | v13 | v14 | Notes |
|---|---|---|---|
| Parser entry | `0x8c32` | `0x8bea` | `void parse(u8 *frag /*r0*/, u32 len /*r1*/)` |
| Literal pool base | `0x8d38` | `0x8cf0` | state-struct ptr, `0x50c`, build ptr |
| `m_ble_packet_timer_id` string | `0x8d44` | `0x8cfc` | ASCII, fed to timer-create |
| CRC helper A `(buf, len)` | `0x8d5c` | `0x8d14` | r0=buf, r1=len |
| CRC helper B `(seed, buf, len)` | `0x8d7e` | `0x8d36` | r0=seed, r1=buf, r2=len |
| CRC table pointer literal | `0x8da0 → 0x84740c` | `0x8d58 → 0x8457c0` | in-body table at `0x2100c` / `0x1f3c0` |
| CRC seed literal (`0xffff`) | `0x8d9c` | `0x8d54` | CRC-16/MODBUS init |

### State buffer layout

The parser derives a per-connection reassembly state struct from a literal-pool pointer, then a `+0xc` field cursor (v13):

```text
0x8c34  mov  r4, r1              ; r4 = fragment length
0x8c36  ldr  r2, [0x8d38]        ; r2 = state base ptr (~0x20a871 RAM)
0x8c3a  subs r2, r2, 1
0x8c3c  strb r1, [r2]            ; flags |= 1 (mark active/busy)
0x8c3e  mov  r5, r2
0x8c40  adds r5, 0xc             ; r5 = &state.hdr (header/accumulator block)
0x8c42  ldrb r2, [r5]            ; r2 = state.phase
0x8c44  mov  r3, r5
0x8c46  adds r3, 8               ; r3 = &state.payload (= hdr + 8)
0x8c48  ldr  r6, [0x8d3c]        ; r6 = 0x50c (max-buffer constant)
```

Header/accumulator block at `r5` (`state+0xc`):

| Off (from r5) | Field | Meaning |
|---|---|---|
| `+0x0` | `phase` (u8) | 0 = expect first fragment, 1 = continuation |
| `+0x1` | `cmd` (u8) | command byte copied from header byte 1 |
| `+0x2` | `accumulated` (u16) | bytes reassembled so far |
| `+0x4` | `length` (u16) | declared payload length (header bytes 2/3) |
| `+0x6` | `crc` (u16) | declared payload CRC (header bytes 4/5) |
| `+0x8` | `payload[]` | reassembly buffer (r3) |

Max payload = `0x50c − 8 = 0x504` (1284) bytes.

### Frame header — instruction-by-instruction

First-fragment branch (`phase == 0`) at v13 `0x8c54`:

```text
0x8c54  cmp  r4, 6              ; need >= 6 header bytes
0x8c56  blo  0x8c9a             ; too short -> return
0x8c58  ldrb r2, [r0]
0x8c5a  cmp  r2, 0xbc           ; byte 0 == magic 0xBC
0x8c5c  bne  0x8c9a             ; bad magic -> return
0x8c5e  strb r1, [r5]           ; phase = 1
0x8c60  ldrb r1, [r0, 1]
0x8c62  strb r1, [r5, 1]        ; cmd = byte 1
0x8c64  ldrb r1, [r0, 3]
0x8c66  ldrb r2, [r0, 2]
0x8c68  lsls r1, r1, 8
0x8c6a  orrs r1, r2
0x8c6c  strh r1, [r5, 4]        ; length = LE u16 (bytes 2,3)
0x8c6e  ldrb r1, [r0, 5]
0x8c70  ldrb r2, [r0, 4]
0x8c72  lsls r1, r1, 8
0x8c74  orrs r1, r2
0x8c76  strh r1, [r5, 6]        ; crc = LE u16 (bytes 4,5)
0x8c78  adds r1, r0, 6          ; src = frag + 6
0x8c7a  subs r2, r4, 6          ; n = len - 6
0x8c7c  mov  r0, r3             ; dst = payload buffer
0x8c7e  bl   memcpy
0x8c82  subs r4, r4, 6
0x8c84  uxth r0, r4
0x8c86  strh r0, [r5, 2]        ; accumulated = len - 6
```

On-wire frame:

```text
byte 0      magic 0xBC
byte 1      cmd
byte 2..3   payload length, little-endian u16
byte 4..5   payload CRC-16, little-endian u16
byte 6..    payload (this fragment's slice)
```

Capacity check after first fragment:

```text
0x8c88  ldr  r2, [0x8d3c]      ; 0x50c
0x8c8a  ldrh r1, [r5, 4]       ; length
0x8c8c  subs r2, 8             ; cap = 0x504
0x8c8e  cmp  r1, r2
0x8c90  bls  0x8c9c            ; length <= cap -> continue
0x8c92  movs r1, 2            ; else error 2
0x8c96  bl   0x8a48            ; report/abort (oversize)
```

### Continuation-fragment accumulation loop

Dispatch is a 3-way on `phase` (v13 `0x8c4a`): `0 → first` (`0x8c54`), `1 → continuation` (`0x8cb4`), else error (`0x8cd4`). The continuation loop (v13 `0x8cb4`):

```text
0x8cb4  ldrh r1, [r5, 2]       ; accumulated
0x8cb6  mov  r2, r4            ; n = fragment length (no header on continuations)
0x8cb8  adds r3, r1, r3        ; dst = payload + accumulated
0x8cba  mov  r1, r0            ; src = fragment
0x8cbc  mov  r0, r3
0x8cbe  bl   memcpy
0x8cc2  ldrh r0, [r5, 2]
0x8cc4  adds r0, r0, r4
0x8cc6  uxth r0, r0
0x8cc8  strh r0, [r5, 2]       ; accumulated += n
0x8cca  ldrh r1, [r5, 4]       ; length
0x8ccc  cmp  r0, r1
0x8cce  blo  0x8cb2            ; still short -> return, wait for next notify
0x8cd0  bl   0x8b2e            ; complete -> dispatch reassembled packet
```

Continuation fragments carry **no** 6-byte header — pure payload appended at `payload + accumulated` until `accumulated >= length`, then `0x8b2e` is the completion/dispatch handler.

### `m_ble_packet_timer_id` timeout

```text
0x8ce2  movs r0, 1
0x8ce6  str  r0, [sp]          ; mode = 1 (repeated/timeout)
0x8ce8  ldr  r1, [0x8d40]      ; BUILD PTR literal (v13 0x82ef99 / v14 0x82ef51) — NOT the interval
0x8cec  movs r3, 0x7d
0x8cf0  lsls r3, r3, 4         ; 0x7d0 = 2000  (the actual timeout)
0x8cf2  adr  r1, str.m_ble_packet_timer_id
0x8cf6  bl   app_timer_create
```

The fragment-timeout interval is the constant `0x7d0` (2000), built by `movs r3,0x7d; lsls r3,r3,4`. The literal `[0x8d40]=0x82ef99` v13 / `[0x8cf8]=0x82ef51` v14 is a build-dependent pointer and must **not** be read as a timer parameter (corrects `RE_FIRMWARE.md` line 67). A setter (`0x8cfc`) stores the timer handle at `state+8`; a getter (`0x8d04`) reads it back. The timer resets a partially-filled reassembly if continuations stop arriving.

### CRC is CRC-16/MODBUS — proven from the table

CRC helper A (v13 `0x8d5c`):

```text
0x8d60  ldr  r0, [0x8d9c]      ; crc = 0xFFFF       (MODBUS init)
0x8d64  ldr  r5, [0x8da0]      ; table ptr -> 0x2100c
        loop:
0x8d68  ldrb r6, [r4, r2]      ; b = buf[i]
0x8d6a  uxtb r3, r0
0x8d6c  eors r3, r6            ; (crc ^ b) & 0xff
0x8d6e  lsls r3, r3, 1         ; * 2 (u16 index)
0x8d70  ldrh r3, [r5, r3]      ; table[idx]
0x8d72  lsrs r0, r0, 8         ; crc >> 8
0x8d74  eors r0, r3            ; crc = (crc>>8) ^ table[idx]
```

Init `0xFFFF`, right-shift, `(crc^byte)&0xff` index, no final XOR/reflection → CRC-16/MODBUS. First 8 table entries dumped from the body match a freshly-computed canonical `poly 0xA001` table:

```text
table[0]=0x0000 table[1]=0xC0C1 table[2]=0xC181 table[3]=0x0140
table[4]=0xC301 table[5]=0x03C0 table[6]=0x0280 table[7]=0xC241
```

v14 (`0x1f3c0`) holds a byte-identical table. **CRC = CRC-16/MODBUS over the declared `length` payload bytes; the 16-bit result is compared against header bytes 4..5.**

### Two CRC helper variants

| Helper | Entry (v13/v14) | Signature | Behaviour |
|---|---|---|---|
| A | `0x8d5c` / `0x8d14` | `crc16(buf, len)` | Hard-codes seed `0xFFFF`; one-shot whole-buffer CRC. |
| B | `0x8d7e` / `0x8d36` | `crc16_seed(seed, buf, len)` | Takes running CRC in `r0`; allows incremental/chained CRC across fragments. |

Both load the same table pointer literal. B omits the internal `0xFFFF` init (caller supplies the seed), enabling fragment-by-fragment CRC accumulation.

### v13 → v14 differences

Parser and CRC loops are **logically byte-for-byte identical**; only literal-pool addresses / RAM-table pointers shift:

| Field | v13 | v14 |
|---|---|---|
| Parser entry | `0x8c32` | `0x8bea` (−0x48) |
| `cmp byte0,0xbc` site | `0x8c5a` | `0x8c12` |
| CRC table (in body) | `0x2100c` | `0x1f3c0` |
| CRC table RAM ptr | `0x84740c` | `0x8457c0` |
| Build-ptr near timer | `0x82ef99` | `0x82ef51` |
| CRC seed literal | `0x8d9c` | `0x8d54` |

No opcode-level changes to frame format, magic, length/CRC endianness, continuation accumulation, capacity guard (`0x504`), timeout (`0x7d0`), or CRC algorithm.

### H59MA file-table response (`0x41` -> `0x42`)

The H59MA-specific file table now has instruction-level evidence in
`firmwares/_re/h59-file-table/evidence.md`. v14 body `0xadb8`
(`FUN_008311b8`) handles `0x41` by copying the 4-byte request cursor, walking
up to 10 records via `0xafba`, formatting each record through `0xac5a`, and
sending response opcode `0x42`.

`0xac5a` proves the `0x42` payload is a generic length-prefixed record list:

```text
payload[0] = record count
record     = [recordLen, recordType, fieldTLVs...]
field      = [fieldLen, fieldId, value...]
```

Both `recordLen` and `fieldLen` are inclusive of their length/id header bytes.
Record types `0x04`, `0x07`, and `0x08` use the 11-id field list
`01 02 03 04 05 06 07 08 09 0d 13`; other record types use
`01 02 04 07 08 09` (inline bytes at `0xae1c`/`0xae28`). Static analysis does
not assign user-facing meanings to those ids, so OpenWatch decodes them as raw
field ids and value bytes.

`0x43` operation handling at v14 body `0xacc8` emits `0x44` metadata before
any `0x45` data chunks. Resolved metadata forms are success
`[00, chunkCount u16LE, meta3, 01, 11]`, not-found
`[01, selector, recordId u32LE]`, and invalid-selector `[02, selector]`.
Chunks are one-based `[chunkIndex, 00, data...]` with data capped at `0x1f4`
bytes.

The earlier `0x46` file-delete inference is rejected. Normal valid-CRC `0x46`
frames bypass async storage in the first-stage dispatcher and call only the
Channel-B cleanup/state helper. If an internal path seeds `cmd = 0x46` into the
async worker, the local file handler at `0xadb8` still returns immediately
because it compares only `0x41` and `0x43`.

The async worker's no-response placeholders are also statically resolved:
`0x13`, `0x29`, and `0x3b` branch directly to worker cleanup, while `0x47` and
`0x4b` call one-instruction `bx lr` stubs at v14 body `0xe3fa` and `0xa060`
with `payload[0]`. These commands do not use the unknown-command NAK path.
The same compare cascade recognizes `0x21..0x24` separately and routes them to
`channel_b_send_nak(cmd, 2)`, while the default unknown path uses
`channel_b_send_nak(cmd, 0)`.

Channel-B `0x2c` alarm read/write is compact on the wire. The read path at v14
`0x9504..0x9592` writes response `[0x01, count]`, then appends variable-length
records `{len, flags, minuteOfDay u16LE, labelBytes...}`. `len` comes from
internal byte 2 masked to 7 bits; `flags` combines internal byte 3 into bit 7
and weekday bytes 6..12 into bits 0..6; `minuteOfDay` is `hour * 60 + minute`.
The write path at `0x9594..0x96ca` decodes the same compact records and sends
the one-byte `[0x02]` ack via the common `0x96cc` sender.

APK-era Channel-B `0x3a` custom-watch-face actions are not implemented in
H59MA v14. The async compare cascade has no `0x3a` branch; valid frames land on
the default `movs r1, 0; bl channel_b_send_nak` path at `0x988a..0x98e6`.

Generic APK FileHandle commands are not implemented either. `0x30`, `0x32`,
`0x33`, and `0x39` have no first-stage special case and no async compare entry,
so valid-CRC frames are queued and then reach the default NAK-code-0 block at
v14 `0x988a..0x98e6`. `0x31` is special only before async storage: v14
`0x8b08` compares `cmd == 0x31`, then `0x8b30..0x8b38` calls the
OTA/file pre-store callback and queues the command. The async worker still has
no `0x31` handler, so it also lands on the same NAK-code-0 path.

High APK album/ebook/record commands `0x80`, `0x81`, and `0x82` are also
absent. On the path for commands greater than `0x47`, v14 checks only `0x4b`
and `0x5a`; non-`0x5a` commands fall through from `0x9886..0x9888` to the
default `0x988a` NAK-code-0 block. v13 has the same shape at
`0x98ca..0x98d2`.

---

## 6. Channel-A Command Dispatch

What the firmware actually contains for Channel-A (`6e40fff0`) command handling — and what it does **not**. All offsets are body offsets.

> **Flash base (load-bearing):** the Channel-B CRC-table pointer pins the base for both builds — `pxw 4 @0x8da0` v13 = `0x0084740c`; `pxw 4 @0x8d58` v14 = `0x008457c0`; both give `0x826400` (`0x84740c − 0x2100c == 0x8457c0 − 0x1f3c0`). This is `0x340` lower than the `~0x826740` implied by the trampoline word (which is the *thumb entry*, not the section base). All pointer searches below use base `0x826400`.

### 1. The opcode bucket table (v13 `@0x22490`)

256 bytes reserved, but only the first `0x82` bytes (opcodes `0x00..0x81`) carry data; the remainder is zero-fill.

```text
r2 -2 -a arm -b 16 -c 'px 256 @0x22490' v13/body.bin
0x00022490  0040 4040 4040 4040 4040 4141 4141 4140
0x000224b0  4005 0202 0202 0202 0202 0202 0202 0202
0x000224d0  0202 9090 9090 9090 1010 1010 1010 1010
0x000224f0  0202 8888 8888 8888 0808 0808 0808 0808
0x00022510  4000 0000 ...                              # opcode 0x80=0x40, then zero-fill
```

```text
opcode 0x00        -> 0x00
opcode 0x01..0x09  -> 0x40      opcode 0x0a..0x0e  -> 0x41
opcode 0x0f..0x20  -> 0x40      opcode 0x21        -> 0x05
opcode 0x22..0x30  -> 0x02      opcode 0x31..0x3a  -> 0x20
opcode 0x3b..0x41  -> 0x02      opcode 0x42..0x47  -> 0x90
opcode 0x48..0x5b  -> 0x10      opcode 0x5c..0x61  -> 0x02
opcode 0x62..0x67  -> 0x88      opcode 0x68..0x7b  -> 0x08
opcode 0x7c..0x7f  -> 0x02      opcode 0x80        -> 0x40
opcode 0x81..0xff  -> 0x00      (zero-fill padding, no meaning)
```

#### The flag is a numeric-range classifier, NOT a r/w/d/notify map

`RE_FIRMWARE.md` and `PROTOCOL.md` §3.3 claim this table "lines up with APK-derived categories (plain / mixture read-write-delete / notify-push)". **It does not.** The flag is purely a function of the opcode's numeric range; mixture and plain commands are scattered across the *same* flags:

| Flag | Opcode range | Mixture commands in range | Plain commands in range |
|---|---|---|---|
| `0x40` | `0x01..0x20`, `0x80` | `0x12,0x16,0x19,0x1b,0x1f` | `0x01,0x02,0x04..09,0x0f,0x13..15,0x1a,0x1e` |
| `0x41` | `0x0a..0x0e` | `0x0a,0x0c,0x0e` | — |
| `0x05` | `0x21` | `0x21` (TargetSetting) | — |
| `0x02` | `0x22..0x30,0x3b..0x41,0x5c..0x61,0x7c..0x7f` | `0x29,0x2a,0x2b,0x2c,0x30,0x3b,0x3d,0x3e,0x3f` | `0x23,0x24,0x25,0x27,0x28,0x3c,0x60,0x61` |
| `0x20` | `0x31..0x3a` | `0x33,0x36,0x38,0x3a` | `0x37,0x39` |
| `0x90` | `0x42..0x47` | — | `0x44` |
| `0x10` | `0x48..0x5b` | `0x52` | `0x50,0x51` |
| `0x88` | `0x62..0x67` | — | — |
| `0x08` | `0x68..0x7b` | `0x7a,0x7b` | `0x72,0x77` |

E.g. `0x40` holds both plain `0x01 SetTime` and mixture `0x12 DisplayClock`; `0x02` holds plain `0x23 SetAlarm` and mixture `0x29 DisplayOrientation`. Best interpretation: a **contiguous-range handler-group routing table**, emitted as a flat `uint8[256]` indexed by raw opcode — not a permission/notify map.

### 2. The table is dead const data — nothing references it

```text
# direct pointer to 0x848890 (= base 0x826400 + 0x22490):
r2 -2 -a arm -b 16 -c '/x 90888400' v13/body.bin      # 0 hits
# brute scan: no word in body lands in 0x848880..0x8488ff at all -> []
```

The four words resolving *near* the table (`0x848754..0x84885c`, at body `0x14d0c/0x14d34/0x170e4/0x170e8`) are **string pointers** into the adjacent peripheral-name blob (`vc30fx_sc`, `I2C0`, `SPI0`, … at body `0x220cc..`), not a bucket base. The runtime 16-byte opcode dispatch lives **phone-side** (Oudmon SDK).

### 3. v14 does not contain the bucket table at all

The three distinctive byte signatures are present exactly once in v13 and **absent** in v14:

```text
/x 4005020202   v13 -> 0x000224b0 (1)   v14 -> (0 hits)
/x 0202909090   v13 -> 0x000224d0 (1)   v14 -> (0 hits)
/x 02028888     v14 -> (0 hits)
/x 0808080808080808  v13 -> 0x224f8, 0x22500
```

Since nothing referenced the table, removing it in v14 was a behavioural no-op.

### 4. The "command literal table" (`0x21b58` v13 / `0x1ff0c` v14) — not a dispatcher

A 20-entry `uint32[]`, byte-identical in both builds: `0x00..0x0b` then `0x50,0x51,0x52,0x53,0x55,0x56,0x58,0x5a`.

```text
r2 -2 -a arm -b 16 -c 'pxw 80 @0x21b58' v13/body.bin   (== v14 @0x1ff0c)
0x00021b58  0x00000000 0x00000001 0x00000002 0x00000003
0x00021b68  0x00000004 0x00000005 0x00000006 0x00000007
0x00021b78  0x00000008 0x00000009 0x0000000a 0x0000000b
0x00021b88  0x00000050 0x00000051 0x00000052 0x00000053
0x00021b98  0x00000055 0x00000056 0x00000058 0x0000005a
```

Unlike the bucket table, this one *is* referenced — and the reference debunks the "command dispatch" framing:

- v13: inline literal pool at body `0x1d458` (word `0x847f58`), routine `0x1d340..0x1d460`.
- v14: absolute pointer at body `0x1c0b8` (word `0x84630c` = base + `0x1ff0c`), routine `0x1c040..`.

The consumer is a **health-metric range-clamp** routine, not an opcode dispatcher. It compares an input against ascending thresholds (`5<<10=0x1400`, `5<<11=0x2800`, `0x23<<10=0x8c00`, `0x5f<<8=0x5f00`, `0x73<<8=0x7300`) and fills a 12-byte buffer:

```text
r2 -2 -a arm -b 16 -c 's 0x1c0c0' -c 'pd 8' v14/body.bin
0x0001c0c0  cmp r2, 0x80          ; compare on a clamped value
0x0001c0c4  movs r7, 0x5f
0x0001c0c6  lsls r7, r7, 8        ; r7 = 0x5f00  (mmHg-style threshold)
0x0001c0c8  cmp r5, r7
...
0x0001c0d0  strb r2, [r4, r3]     ; fill 12-byte buffer, idx ..0xc
```

The `0x50..0x5a` values are reused as small integer constants here, not live BLE opcodes.

### 5. Bottom line

The v13-only bucket table (`0x22490`, unreferenced) and the literal array
(`0x21b58`/`0x1ff0c`, used only by a health clamp) are not the runtime
dispatcher. v14 does contain a firmware Channel-A queued-frame dispatcher at
`0x0082d2dc` (see `firmwares/GHIDRA_DECOMPILATION.md` §3); it strips/processes
the queued opcode and calls explicit per-opcode handlers rather than indexing
the dead bucket table.

---

## 7. BLE GATT Attribute Tables *(unverified)*

> *Marked unverified only because the independent verifier corrected one cell — the v14 Device Name `0x2a00` value-UUID offset is `0x1f364` (decl `0x2803` @`0x1f362`), not `0x1f366`. Everything else reproduced exactly.*

All 128-bit UUIDs are stored **little-endian** (16 bytes reversed vs human-readable form); 16-bit UUIDs are 2 LE bytes (e.g. `0x180a` → `0a 18`). Every offset is a **body** offset (add `0x450` for container). Offsets below are the start of the actual UUID bytes (re-extracted via `/x`), so a few differ from the prior notes — see §2.

### Service / characteristic inventory (both bodies)

**Four** GATT services, identical counts in v13/v14: **4 service decls (`0x2800`), 11 char decls (`0x2803`), 4 CCCDs (`0x2902`)**.

```text
v13 (0x20c72..0x21006):  0x2800 -> 4   0x2803 -> 11   0x2902 -> 4
v14 (0x1f026..0x1f3a0):  0x2800 -> 4   0x2803 -> 11   0x2902 -> 4
```

| Service | Role | UUID | v13 svc-UUID off | v14 svc-UUID off |
|---|---|---|---:|---:|
| Device Information | std read-only info | `0000180a-…` | `0x20c78` | `0x1f02c` |
| Channel B | large-data / file / OTA | `de5bf728-d711-4e47-af26-65e3012a5dc7` | `0x20d7c` | `0x1f130` |
| Channel A | fixed-length command | `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` | `0x20e40` | `0x1f1f4` |
| **`0xfee7` (NEW)** | vendor (Chinese-vendor "fee7") | `0000fee7-…` | `0x20f08` | `0x1f2bc` |

Verbatim search hits for the 128-bit vendor UUIDs (LE patterns):

```text
/x c75d2a01e36526af474e11d728f75bde  v13 -> 0x00020d7c   # ChanB svc de5bf728
/x 9ecadc240ee5a9e093f3a3b5f0ff406e  v13 -> 0x00020e40   # ChanA svc 6e40fff0
/x e7fe                              v13 -> 0x00020f08   v14 -> 0x0001f2bc   # fee7 svc
```

**Characteristic value-UUID offsets:**

| Char | UUID | v13 off | v14 off | Notes |
|---|---|---:|---:|---|
| Serial number | `0x2a25` | `0x20cae` | `0x1f062` | DevInfo |
| HW revision | `0x2a27` | `0x20ce6` | `0x1f09a` | DevInfo |
| FW revision | `0x2a26` | `0x20d1e` | `0x1f0d2` | DevInfo |
| System ID | `0x2a23` | `0x20d56` | `0x1f10a` | DevInfo |
| ChanB write | `de5bf72a-…` | `0x20dc6` | `0x1f17a` | write |
| ChanB notify | `de5bf729-…` | `0x20dfe` | `0x1f1b2` | notify + CCCD |
| ChanA write | `6e400002-…` | `0x20e8a` | `0x1f23e` | write |
| ChanA notify | `6e400003-…` | `0x20ec2` | `0x1f276` | notify + CCCD |
| fee7 write | `0xfea1` | `0x20f3e` | `0x1f2f2` | write + CCCD (NEW) |
| fee7 read | `0xfec9` | `0x20f92` | `0x1f346` | read (NEW) |
| fee7 notify | `0xfea2` | `0x20fca` | `0x1f37e` | notify + CCCD (NEW) |
| Device Name | `0x2a00` | `0x20fb0` | `0x1f364` | in fee7 block (NEW; was mis-ID'd as `0x2a28`) |

In-table CCCDs (`0x2902`, LE `0229`):

```text
v13: 0x20e1a (ChanB), 0x20ede (ChanA), 0x20f5a (fee7/fea1), 0x20fe6 (fee7/fea2)
v14: 0x1f1ce,         0x1f292,         0x1f30e,             0x1f39a
```

> The "SW revision `0x2a28`" in the prior notes is a **phantom**: `s 0x20fad; px 8` → `00 03 28 2a 00` — the bytes are char-decl `0x2803` then value UUID `0x2a00`; the `282a` straddles the field seam. DevInfo therefore has **4** chars, not 5.

### Attribute-table structure

The table is an array of fixed **`0x1c` (28)-byte** records (half-word aligned; base `0x20c72`/`0x1f026`). Each declared characteristic = two records (a `0x2803` declaration + the value record) = `0x38` bytes; the value-UUID stride between consecutive characteristics is exactly `0x38`.

```text
char-decl (0x2803) offsets v13: 0x20c92, 0x20cca, 0x20d02, 0x20d3a ... (step 0x38)
value-UUID offsets         v13: 0x20cae, 0x20ce6, 0x20d1e, 0x20d56 ... (step 0x38)
```

16-bit-UUID record (DevInfo char-decl at v13 `0x20c92`):

```text
s 0x20c92; px 0x1c
0x20c92  03 28 02 00 00 00 ... 01 00 00 00 00 00 01 00 00 00 04 00
         |type |          padding/value          | perm/flags |len|
         0x2803                                   0x00010000   0x0004
```

Service-declaration record (`0x2800` at v13 `0x20c76`):

```text
0x20c76  00 28 0a 18 00 00 ... 02 00 00 00 00 00 01 00 00 00 02 00
         0x2800 |0x180a inline UUID|         flags        |len 0x0002
```

128-bit services/characteristics carry the full inline 16-byte UUID plus a `0x05` type tag and a flash value pointer. Channel-B service decl (v13 `0x20d7c`):

```text
0x20d7c  c7 5d 2a 01 e3 65 26 af 47 4e 11 d7 28 f7 5b de   # inline 128-bit UUID
0x20d8c  00 08 00 28 ...                                   # 0x2800 svc-decl, perm 0x0800
0x20d9c  00 00 10 00 7c 71 84 00 ...                       # value-ptr -> 0x0084717c
...      05 00 c7 5d 2a 01 ...                             # 0x05 tag + ChanB write UUID 72a
```

The `0x05` byte preceding each 128-bit UUID is the "128-bit UUID" type indicator (vs inline 16-bit). The trailing `0x0084xxxx` words are flash pointers into the value/handler region.

The words immediately before the v14 `0xfee7` service declaration are the
**Channel-A callback block**, not FEE7 handlers:

```text
s 0x1f2b0; pxw 0x20  v14/body.bin
0x1f2b0  0x0082e87b 0x0082e8cf 0x28000802 0x0000fee7   # Ch-A write/CCCD callbacks, then fee7 svc decl
0x1f3b0  0x00000011 0x0082e9a3 0x0082ea4d 0x0082eabb   # true fee7 callbacks
```

### Two-channel transport (confirmed) + a third surface

- **Channel A** `6e40fff0` — write `6e400002` + notify `6e400003` (+CCCD): fixed-length command channel (Nordic-UART-derived `6e40xxxx` range).
- **Channel B** `de5bf728` — write `de5bf72a` + notify `de5bf729` (+CCCD): large-data / file / OTA channel (matches the `0xbc`-magic fragmented parser, §5).
- **`0xfee7` (NEW)** — write `0xfea1`, read `0xfec9`, notify `0xfea2` (both notifies CCCD-backed), plus a Device Name `0x2a00` value: the standard Chinese-vendor "fee7" profile, present in both bodies but absent from the prior notes. A 2026-07-05 radare2 pass shows the true FEE7 registration uses table `0x1f2b8` and callback block `0x1f3b2`; its write callback wraps a generic Realtek service event and does **not** call the 16-byte opcode dispatcher. See `firmwares/_re/fee7-gatt/evidence.md`.

---

## 8. Strings, Assets & Capabilities *(unverified)*

> *Marked unverified only because the verifier corrected the v14 phone-compat table offset to `0x1f5e0` (the `DUK-AL20` start row); the previously cited `0x1f610` is the 4th (`SM-N970U`) row mid-table. v13 `0x2122c` is correct. Everything else reproduced.*

Commands run with `R2='r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0'`.

### There is no embedded JPEG (or any raster asset)

`RE_FIRMWARE.md` (layout line 35) lists an "Embedded JPEG" at v13 `0x21eef` / v14 `0x202a3`. This is wrong:

```text
$R2 -c '/x ffd8ffe0' v13/body.bin   # JFIF SOI -> (no hits)
$R2 -c '/x ffd8ffe1' v13/body.bin   # Exif SOI -> (no hits)
$R2 -c '/x ffd8ffdb' v13/body.bin   # raw SOI  -> (no hits)
$R2 -c '/ JFIF' / '/ Exif' v13/body.bin   # (no hits)
$R2 -c '/x 89504e47' v13/body.bin   # PNG  -> (no hits)
$R2 -c '/x 474946383' v13/body.bin  # GIF8 -> (no hits)
```

The only `ff d8 ff` run is at v13 `0x21a9f`, immediately followed by `FF FF FF 21` (not a valid APPn marker) — it is sign-extended 32-bit table data:

```text
$R2 -c 's 0x21a9f; px 16' v13/body.bin
0x00021a9f  ffd8 ffff ff21 0000 00e9 ffff ff21 0000  .....!.......!..
```

The sole `ff d9` in v13 is at `0xbc1c` (inside code); v14 has **no** `ff d9` at all — impossible if a JPEG were present. What actually sits at v14 `0x202a3` is the ANCS app-package string table:

```text
$R2 -c 's 0x202a3; px 32' v14/body.bin
0x000202a3  5465 6c65 6772 6170 6800 0000 0063 6f6d  Telegraph....com
0x000202b3  2e66 6163 6562 6f6f 6b2e 4661 6365 626f  .facebook.Facebo
```

The region (incl. `Scene_B`/`Scene_C` markers) is identical in both builds — not an asset. The "6561 vs 6057" figures correspond to no locatable image; the size reduction is debug-string/code removal (§9).

### Version / build / SDK identifiers

| Token | v13 | v14 | Source |
|---|---|---|---|
| `H59MA_1.00.13_251230` / `…14_260508` | `container:0x10`, body `0xa918`/`0xa8d0` | | header + body |
| `H59MA_V1.0`, `H59MA_`, `H59MAX_` | `0x8784`, `0x8790`, `0x8594` | `0x873c` etc | `/ H59MA` |
| `Thu Mar 17 10:58:10 2022` | `0x45c` | `0x380` | `izz~Thu` — **identical in both → baked `__DATE__/__TIME__`, not a real build time** |
| `sdk lib version: %d.%d.%d.%d ,commit ID:%x` | `0x1f5a0` | `0x1e238` | on-wire SDK version report |
| `core30fx_v0.23` | `0x21354` | `0x1f708` | sensor/algorithm core version |
| `sdk#####` | `container:0xb8` | `container:0xb8` | header pad |

### RTOS / SoC platform (Realtek "Bee")

```text
$R2 -c '/ dlps' v13/body.bin        # 0x401e  "allowed enter dlps"  (Realtek DLPS)
$R2 -c '/ PTA_Mailbox' v13/body.bin # 0x222cc  (BT/WiFi coexistence)
```

Peripheral / IRQ name table (body `~0x221d0..0x22300`): `GDMA0 Channel0..3`, `GPIO_Group0..3`, `Enhanced_Timer0/1`, `Timer4-5`, `I2C0/1`, `I2S0_RX/TX`, `SPI0/1/2W`, `SPI_Flash`, `UART0/1`, `LPCOMP`, `TRNG`, `Keyscan`, `Qdecode`, `CAP_Touch`, `BTMAC`, `PTA_Mailbox`, plus Cortex-M vector names (`InitialSP`, `Reset`, `HardFault`/`BusFault`/`MemManage`/`UsageFault`/`DebugMon`/`SysTick`/`PendSV`). TRNG is the only hardware crypto primitive.

### BLE / ANCS / notification stack

| Category | Tokens |
|---|---|
| GATT server | `gatts_add_client` (v13 `0x21d14`, v14 `0x200c8`) |
| LE vendor HCI | `le_vendor_update_conn_param`, `le_vendor_set_priority`, `le_vendor_drop_acl_data` |
| ANCS client | `ancs_init/add_client/client_cb/get_app_attr/handle_msg/send_msg_to_app`, `app_parse_notification_source_data` |
| App tasks/timers | `app_main_task`, `hub_task(_init)`, `send_msg_to_hub_task`, `m_ble_packet_timer_id`, `m_heart_rate_timer_id`, `m_motor_timer_id`, `m_ota_write_flag_id`, `con paramter update timer` (sic) |

**ANCS app-ID allowlist** (v13 `~0x21f44..0x22050`, v14 `~0x206a0..`): `com.apple.MobileSMS`, `com.apple.mobilephone`, `com.tencent.tim/xin/mqq/mipadqq`, `net.whatsapp.WhatsApp`, `com.facebook.Facebook/.Messenger`, `com.google.Gmail`, `com.linkedin`, `com.skype.skype`, `com.viber`, `com.burbn.instagram`, `com.atebits.Tweetie2`, `com.tumblr.tumblr`, `com.toyopagroup.picaboo` (Snapchat), `ph.telegra.Telegraph`, `jp.naver.line`, `vn.com.vng.zingalo` (Zalo).

### Phone-compatibility / connection-parameter table (NEW)

Fixed 16-byte-record table of handset model codes (name `00`-padded, then two parameter bytes), v13 `0x2122c`, **v14 `0x1f5e0`** (the `DUK-AL20` start; `0x1f610` is the 4th row, mid-table):

```text
$R2 -c 's 0x2122c; px 0x60' v13/body.bin
0x0002122c  4455 4b2d 414c 3230 0000 0000 0000 0a0c  DUK-AL20........
0x0002123c  564f 472d 414c 3030 0000 0000 0001 0a0c  VOG-AL00........
0x0002124c  534d 2d47 3937 3555 0000 0000 0000 0a0c  SM-G975U........
0x0002125c  534d 2d4e 3937 3055 0000 0000 0000 0a0c  SM-N970U........
0x0002126c  434c 542d 414c 3030 0000 0000 0000 0f14  CLT-AL00........
0x0002127c  0000 0000 bf04 8300 c104 8300 c304 8300  ........ (ptrs)
```

Models: `DUK-AL20` (Honor V9/8 Pro), `VOG-AL00` (Huawei P30 Pro), `SM-G975U` (Galaxy S10+), `SM-N970U` (Galaxy Note10), `CLT-AL00` (Huawei P20 Pro). Trailing `0a 0c` / `0f 14` are per-model BLE conn-interval / latency overrides; the `bf 04 83 00`-style words are `0x008304bf` flash pointers (confirming the `0x82xxxx`/`0x83xxxx` flash range).

### Sensor / health-algorithm libraries (capabilities)

```text
$R2 -c '/ lib_BIODetect'  v13/body.bin   # 0x232f4  lib_BIODetect_V14_1
$R2 -c '/ VC_HRV'         v13/body.bin   # 0x23094  VC_HRV_16Bit_integration_6.0_addRMSSD
$R2 -c '/ spo2_VC30F'     v13/body.bin   # 0x23326  spo2_VC30F_S_int_limit_ed01
$R2 -c '/ vc30fx'         v13/body.bin   # 0x220cc  vc30fx_sc
$R2 -c '/ vc_SportMotion' v13/body.bin   # 0x23358  vc_SportMotion_Int
```

`VC*/vc30fx` is the **Vcare/vc30** PPG optical-sensor algorithm suite. Capabilities:

- **Heart rate** — `m_heart_rate_timer_id`, `hr_realtime_test_id`, `hr_module.c`, `VC_HRV` (HRV incl. RMSSD).
- **SpO2** — `spo2_VC30F_S_int_limit_ed01`.
- **Motion / sport / step** — `vc_SportMotion_Int`, `sports_mode_timer`, `app_ring_sport_data_id`, accelerometer `lis3dh_spi.c` (ST LIS3DH 3-axis), `gsensor_read_timer_id`, `gsensor_shake_flag_timer_id`.
- **Sleep staging** (v13 only; ~60 debug strings at `0x1b800+`): `]hr deep=%d,count=%d/%d`, `]drop off`, `]return sleep`, `]set sleep hr:%d`, `]not wear`, `]nap awake finish`.
- **Haptics** — `m_motor_timer_id`, `long press timer`, `debounce timer`.
- **No GPS** — no GPS/GNSS/NMEA/location strings anywhere.

### Build-environment / source-path leaks

```text
$R2 -c '/ qc_code' v13/body.bin
0x0000d018  ..\..\..\..\qc_code\app_module\gsensor\lis3dh_spi.c
0x0000d4c4  ..\..\..\..\qc_code\app_module\hr\hr_module.c
```

Vendor namespace `qc_` (`qc_app`, `qc_timer_restart`); config store via `_cfg_write_to_flash`, `cfg_add_item`, `cfg_del_item`, with debug formats `old/new config len %d`, `item[%02x] found!`, `Header is invalid`.

### URLs / MAC / crypto — explicit negatives

- **No URLs**: `/ http`, `/ www.` → no hits.
- **No literal MAC/OUI**: only the symbolic `BTMAC` peripheral and the factory message `Ready to update MAC!` (v13 `0x1b3d4`). No hard-coded address/OUI.
- **No AES / SHA / MD5 / CRC32**: AES S-box (`63 7c 77 7b f2 6b 6f c5`), AES Te0 (`a5 63 63 c6`), SHA-256 init (`67 e6 09 6a`), MD5 init (`01 23 45 67`), reflected CRC32 poly (`20 83 b8 ed`) — all **no hits**. The only checksum primitive is CRC-16/MODBUS. Hardware `TRNG` exists but no software cipher constants — OTA/config integrity relies on the additive container checksum + CRC-16, not signing or AES.

### OTA / DFU tokens

`m_ota_write_flag_id`, `BootOnce` (v13 `0x21f34`), `wrong signature! Read %8X != Requried %8X` (v13 `0x1b5c8`, sic — a 32-bit magic compare gating the update, not a cryptographic signature), `Ready to update MAC!`, `con paramter update timer`. `BootOnce` + the dual flash addresses (`0x826000`/`0x826400`) indicate a one-shot boot-flag / dual-bank-style update flow.

---

## 9. v13 → v14 Diff: a Debug-Logging Strip, Not a Feature Change

The body shrank from `144448` to `136700` bytes (`−7748`, `−0x1e44`). It is **not** a uniform truncation and **not** a protocol change — it is dominated by removal of the sleep-staging **debug-logging** subsystem (trace strings + their call sites). The wire protocol is byte-for-byte unchanged.

### 1. The structural delta is tiered

Subtracting `v13 − v14` offsets of anchors present in both bodies shows the gap growing in discrete steps — proving multiple distinct removals, the biggest where the sleep debug strings live:

| Anchor (body offset) | v13 | v14 | delta |
|---|---:|---:|---:|
| `m_heart_rate_timer_id` | `0x5764` | `0x56c4` | `0xa0` (160) |
| ChanB parser entry | `0x8c32` | `0x8bea` | `0x48` (72) |
| `battery_sample_power_on` | `0x9a60` | `0x9a18` | `0x48` (72) |
| `spi` | `0xd00c` | `0xcfc4` | `0x48` (72) |
| `sdk lib version:` | `0x1f150` | `0x1dde8` | `0x1368` (4968) |
| `gatts_add_client` | `0x218c4` | `0x1fc78` | `0x1c4c` (7244) |
| `le_vendor_drop_acl_data` | `0x21adc` | `0x1fe90` | `0x1c4c` (7244) |
| `com.atebits.Tweetie2` | `0x21f40` | `0x20234` | `0x1d0c` (7436) |

Code below `~0xd00c` shifts only `0x48`–`0xa0` (a small early edit, ~72 B net). The delta jumps to `0x1368` by `0x1f150` — **~4896 bytes removed between `0xd00c` and `0x1f150`**, exactly the sleep cluster (§2). Another ~`0x8e4` is removed before `gatts_add_client`, reaching the steady `0x1c4c`. The remaining `0x1e44 − 0x1c4c = 0x1f8` is v13's trailing tables (opcode bucket etc.) that v14 drops entirely.

### 2. What was removed: the sleep-staging debug logger

v13 has **47** distinct `"%02d:%02d]…"` trace strings; v14 has **0**.

```text
$ izz~%02d:%02d] v13/body.bin | wc -l   ->  47
$ izz~%02d:%02d] v14/body.bin | wc -l   ->   0
$ izz~drop off   v13/body.bin
0x0001f72c  %02d:%02d]unwear_minute drop off
0x0001f830  %02d:%02d]drop off to movement
0x00020090  %02d:%02d]drop off
$ izz~drop off   v14/body.bin            ->  (nothing)
```

A sleep-state-machine debug log (`drop off`, `return sleep`, `awake get hr=%d`, `hr deep=%d,count=%d/%d`, `nap awake finish`, `sleep algorithm reset`, `not wear`, …). The string blob spans v13 `0x1b728..0x206bc` (~1253 string bytes); the larger saving is the **emitting code** (dozens of ~200–460 B divergent windows in container `0x1b000–0x1f000`), accounting for the bulk of the ~4.9 KB cut. Natural-string counts corroborate a net strip: `519` (v13) vs `459` (v14).

### 3. Protocol is UNCHANGED (compatibility conclusion)

| Structure | Check | Result |
|---|---|---|
| CRC-16/MODBUS table | `px 32` v13 `0x2100c` vs v14 `0x1f3c0` | identical (`0000 c1c0 81c1 4001 …`) |
| ChanB parser code | `pi 6` v13 `0x8c32` vs v14 `0x8bea` | identical; only literal addr `0x8d38`→`0x8cf0` shifts |
| Channel A service UUID | `px 16` v13 `0x20e40` vs v14 `0x1f1f4` | identical (`9eca dc24 0ee5 a9e0 93f3 a3b5 f0ff 406e`) |
| Command literal table | `px 48` v13 `0x21b58` vs v14 `0x1ff0c` | identical (`00..0b` LE u32 sequence) |

```text
$ s 0x8c32; pi 6  v13/body.bin
push {r4, r5, r6, lr}; mov r4, r1; ldr r2, [0x00008d38]; movs r1, 1; subs r2, r2, 1; strb r1, [r2]
$ s 0x8bea; pi 6  v14/body.bin
push {r4, r5, r6, lr}; mov r4, r1; ldr r2, [0x00008cf0]; movs r1, 1; subs r2, r2, 1; strb r1, [r2]
```

**v13 and v14 are wire-compatible.** A host/app that talks to v13 talks to v14 with no protocol adaptation.

### 4. Opcodes / capability flags

No opcode-set change. The command literal table is byte-identical (§3). The only opcode-related difference: v13's one-byte bucket table at `0x22490` has **no** byte-identical counterpart in v14:

```text
$ s 0x22490; px 16  v13/body.bin
0x00022490  0040 4040 4040 4040 4040 4141 4141 4140
$ /x 0040404040404040404041  v14/body.bin   ->  (no hit)
```

The table sits in v13's trailing region (`0x21576..0x23440`) which v14 simply does not have (v14 ends at `0x215fc`). Since nothing referenced the table (§6), this is a dead-table cleanup, not an opcode change.

### Summary

`−7748` bytes = (a) a small early code edit (~72 B), (b) the dominant removal of the sleep-staging debug-logging subsystem (47 trace strings + call sites, ~4.9 KB in `0x1b000–0x1f000`), and (c) v13's trailing opcode-bucket/aux tables (~`0x1f8`) that v14 omits. A **debug strip + dead-table cleanup**, with **zero protocol impact**.

---

## 10. Open Questions

1. **`image_digest` algorithm** — the 32-byte `0x1c4` field is SHA-256-sized, but no SHA-256 init constants exist in the body (§8 crypto negatives). The runtime OTA body checks only the first container word, strips file offset `0x50`, stages the digest-containing region as raw data, and checks final staged length (`expected_size - 0x50`). Is the digest computed by the build host only (never verified on-device), or verified by ROM/bootloader code outside this OTA slice?
2. ~~**`0x0C` additive checksum exact formula**~~ — **resolved:** `sum(container[0x50:]) & 0xffffffff` (observed high byte `0x00`) matches both v13 and v14. It is not over `body` or `container[0x60:]`.
3. **Header constants** — `const_228 = 0x0e85d101` is now mapped to the `flash_app_end` target marker (`0x0e85d101,0x00000001`) before the linked runtime tail; `const_5c = 0x7e6b4cf9` is the head of the constant GUID. `const_b4 = 0x1201a39e` remains header-only in the available v13/v14 bodies: no body literal hit or xref was found.
4. ~~**`0xfee7` vendor service active command path**~~ — **resolved for static routing:** `0x0082e87b`/`0x0082e8cf` are Channel-A callbacks immediately before the FEE7 table. The true FEE7 callbacks are `0x0082e9a3`/`0x0082ea4d`/`0x0082eabb`; FEE7 write events go through the common service-event callback and do not branch to the 16-byte dispatcher. Live captures are still useful to determine whether any host uses the profile for opaque side effects.
5. ~~**`wrong signature! Read %8X != Requried %8X`**~~ — **resolved:** this is `cfg_blob_magic_ok` at v14 body `0x1a324` / absolute `0x00840724`, not an OTA or bootloader signature. It reads the first little-endian u32 of a persistent config blob and compares it with `0x8721bee2`; callers are `cfg_find_item` (`0x00840be0`) and the item-`0x33` reader (`0x0084415c`, base `0x00801400`, length `6`).
6. **Boot/vector region** — the real Cortex-M vector table, reset handler, and the `BootOnce` dual-bank logic live in flash ≤`0x826400`, outside both OTA bodies. Obtaining a full-flash dump would let us verify the load/verify path end-to-end.
7. **`flash_app_end @0x22c` bootloader use** — the pointer target is now mapped: v13 body `0x21460` / v14 body `0x1f814`, the unique `0x0e85d101,0x00000001` marker immediately before allocator/runtime string and pointer tables (`malloc`, `calloc`, `realloc`, etc.). The runtime body has no direct xrefs to the pointer value or marker. Whether the bootloader/apply path enforces this boundary still requires a full lower-flash dump.
