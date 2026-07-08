# Residual Protocol Surface — Master Evidence (H59MA v14)

Date: 2026-07-08  
Scope: `firmwares/_re/v14/body.bin`  
Base mapping: **flash = body_offset + `0x00826400`**

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826400 \
  firmwares/_re/v14/body.bin
```

Companion tables: [`../full-opcode-inventory/inventory.md`](../full-opcode-inventory/inventory.md).

Canonical priors: `vendor-high-audit`, `fee7-high`, `channel-b-dispatch`,
`ota-container`, `h59-file-table`, `digest-and-boundary`, `ch-a-dispatch-audit`.

---

## Coverage summary

| Area | Static coverage | Notes |
|---|---|---|
| Low vendor handlers `0x02,03,04,0a,0c,0d,10,16,19,21` | **~95% wire** | Request/response bytes recovered; a few value *semantics* still opaque |
| High `0x91..0xa0` | **~95% wire** | `0xa0` field sources fully mapped; some flag meanings need live capture |
| Channel-B OTA state machine | **~90%** | States, packets, NAK codes, size per-pocket cap; host 12 MB cap not enforced in body |
| File-table field IDs | **~85%** | fieldId → record offset + width; user-facing names not in firmware |
| `image_digest @0x1c4` | **100% negative** | Exhaustive hash/HMAC/CRC failed; no body validation; bootloader absent |
| Channel-A deferred inventory | **100% of tree** | Every `cmp` arm listed with handler address |
| `qc_app_task` tick order | **~90%** | Full call order; some helper names remain generic |

**Inventory coverage (static wire completeness): ~92%** of residual targets in this pass.

---

## 1. Low-range vendor handlers (immediate path)

Dispatcher body `0x0082c5f6` → low switch8 table `0x0082c61c`.  
Thunks pass `r0 = frame` then `bl` callee; epilogue `pop {r4,pc}` at `0x0082c752`.

| Op | Thunk flash | Callee flash | Body | Role |
|---:|---:|---:|---:|---|
| `0x02` | `0x0082c788` | `0x0082c4d4` | `0xc4d4` | Camera / remote shutter control |
| `0x03` | `0x0082c7b2` | `0x0082bc7e` | `0x587e` | Battery status |
| `0x04` | `0x0082c7ba` | `0x0082c432` | `0xc432` | Bind / ANCS model |
| `0x0a` | `0x0082c79c` | `0x0082b9c6` | `0xb9c6` | Time-format / related settings |
| `0x0c` | `0x0082c7e2` | `0x0082c0de` | `0xc0de` | BP setting |
| `0x0d` | `0x0082c7fa` | `0x00834252` + `0x0082c0a4` | `0xde52`/`0xc0a4` | BP history prep + chunk send |
| `0x10` | `0x0082c794` | `0x0082b9a8` | `0xb9a8` | Short alert |
| `0x16` | `0x0082c7d2` | `0x0082c164` | `0xc164` | Heart-rate setting |
| `0x19` | `0x0082c7a4` | `0x0082c484` | `0xc484` | Degree unit |
| `0x21` | `0x0082c804` | `0x0082bfd8` | `0xbfd8` | Daily targets |

### 1.1 `0x02` camera (`0x0082c4d4`)

**Request:** 16-byte frame; effective action in `req[1]` ∈ `{4,5,6}` (enter UI / keep-on / finish).  
**Guards:** returns silently if health session helper `0x00828af4` ≠ 0 **or** service state `*0x208d30 ≠ 3`.  
**Effect:**
- `req[1]∈{4,5}` → `bl 0x833364(1)`
- `req[1]==6` → `bl 0x833364(0)`
- else → self-style notify via `0x0082b986(opcode=2, …)` with zeros  
**Response:** no dedicated multi-byte status on success path; optional fixed ACK path via `0x0082b986`.  
**Wire note:** APK CameraReq action ≥4 ≤6 matches firmware compares.

### 1.2 `0x03` battery (`0x0082bc7e`)

**Request:** bare opcode (payload ignored).  
**Response (16B, additive cksum @15):**
```
[0]=0x03
[1]=battery_percent   // 0x008289a2 — reads *(0x209dbc+0x10), clamp ≤0x64
[2]=charging_flag     // 1 if 0x00828af4()!=0 else 0
[3..14]=0
[15]=sum
```

### 1.3 `0x04` bind/ANCS (`0x0082c432`)

**Request:**
```
[0]=0x04
[1]=verBucket / mode byte  →  bl 0x00827632(req[1])
[2]=flag / length context
[3..14]=UTF-8 model (≤12B) → stored via 0x0082ff4c(len_or_0, &req[3])
```
**Response:** self-marker ACK `[0x04, 0…, 0x04]` (byte 0 and 15 = opcode) then model-store side effects.  
If internal flag `0x0082762c()==1` and probe `0x0082d754()==0`, also schedules timer `0x0082fdda(0x1f4)`.

### 1.4 `0x0a` settings (`0x0082b9c6`)

**Request:** `req[1]==1` read; else write.  
**Write path:**
- `req[3]` → time-format helper `0x008276d8` + commit `0x008319b0`
- if `req[0xb]≠0`: copy `req[0xa..0xb]` → `*(0x2089fc+6..7)`
- if `req[6]≠0`: `0x00827702(req[4],req[5],req[6],req[7])`  
**Write response:**
```
[0]=0x0a, [1]=0x02, [2]=req[2], [3]=req[3], [15]=cksum
```
**Read response:**
```
[0]=0x0a, [1]=0x01, [2]=0, [3]=time_format_read(),
[0xa..0xb]=saved pair from 0x2089fc+6, [15]=cksum
```

### 1.5 `0x0c` BP setting (`0x0082c0de`)

**Request:** sub at `req[1]`:
- `1` read → build 7-byte body via `0x008341d4`, stream with opcode `0x0c` length 7 (`0x0082b938`)
- `2` write → `0x00834210` then ACK via `0x0082b986`  
**Response (read):** opcode-mirrored streamer frame with 7 payload bytes (layout owned by BP setting blob).

### 1.6 `0x0d` BP history (`0x0082c7fa`)

```
bl 0x00834252   ; prepare recent days
bl 0x0082c0a4   ; send chunks
```
`0x0082c0a4` builds stack buffers, calls `0x00834296`, then emits one or two `0x0d` streamer frames (`0x0082b938`) with 14-byte chunks / remaining length. Empty → no emit when helper returns `0xFF`.

### 1.7 `0x10` short alert (`0x0082b9a8`)

**Request:** bare (payload unused).  
**Effect:**
1. `bl 0x0082a460(0xc8)` — vibration/motor pattern duration-ish
2. `bl 0x0082994c(0x14, 1, 1, 2)` — UI/display pulse
3. `bl 0x0082b986(0x10, 0)` — ACK notify opcode `0x10`  
**Response:** compact ACK via shared builder (`0x10` at frame[0]).

### 1.8 `0x16` HR setting (`0x0082c164`)

**Request:** `req[1]` sub, `req[2]` enable-ish, `req[3]` interval/value.  
- `req[1]==1` read: response `[0x16, req[1], enable_01_or_02, stored@0x2089fc+0xc, 0x05, …, cksum]`
- else write: clear/set HR bit helper `0x0082769a` / store `req[3]` at `0x2089fc+0xc`; `0`/`0xFF` coerce to default `5`; echo `[0x16, req[1], req[2], …]`

### 1.9 `0x19` degree unit (`0x0082c484`)

**Request:** `req[1]==1` read else write.  
- write: `req[3]==1` → set unit helper `0x008277ba(1)` else `0`; response echoes `req[1]`, zeros `[2]`, `req[3]` in `[3]`  
- read: `[0x19,1,0, unit_read(), …, cksum]` via `0x008277ae`

### 1.10 `0x21` daily targets (`0x0082bfd8`)

**Request:**
- `req[1]==1` **read** → fill LE24 step/cal/dist into response bytes `[2..10]`
- else **write** LE24 triples:
```
steps = req[2] | req[3]<<8 | req[4]<<16
cal   = req[5] | req[6]<<8 | req[7]<<16
dist  = req[8] | req[9]<<8 | req[10]<<16
```
optional extended `sportMin u16LE @11..12`, `sleepMin u16LE @13..14` when present (handler continues past base triple).  
Commits via `0x00827732` + sport helpers; echoes full 16-byte request frame after checksum.

---

## 2. High-range `0x91..0xa0`

Cascade + switch8 table `0x0082c6e0` (see `vendor-high-audit`).

| Op | Callee | Request | Response |
|---:|---:|---|---|
| `0x91` | `0x00827aee` | bare | `[0x91,0…, additive_cksum]` — true checksum ACK |
| `0x92` | `0x00827b14` | bare | **none** (`bx lr`) |
| `0x93` | `0x00827c4a` | bare | Frame1 self-marker `[0x93…0x93]`; Frame2 ASCII `"1.00.14_" + "260508"` (or blob0 overrides) in `[1..14]` + cksum |
| `0x94` | `0x00827b2e` | bare | self-marker `[0x94…0x94]`; sets mode byte `*(0x209d8a)=1`; arms timer helper |
| `0x95` | `0x00827b54` | bare | self-marker; `*0x209d8a=3`, clears `*(0x209d8a+1)` |
| `0x96` | `0x00827b7c` | bare | self-marker; mode `4` + drain worker |
| `0x97` | `0x00827ba4` | bare | **none** |
| `0x98` | `0x00827be6` | bare | session mode `1` + self-marker |
| `0x99` | `0x00827bea` | bare | **none** |
| `0x9a` | `0x00827bec` | bare | session mode `2` + self-marker |
| `0x9b` | `0x00827bf0` | bare | `[0x9b, statusByte, …, cksum]` status `0x88` if mode2 else `0x77` |
| `0x9c` | `0x00827c1e` | bare | self-marker then factory-stop cleanup |
| `0x9d` | `0x0082bcba` | any | **vendor NAK** `[0x9d\|0x80, 0xee, …]` |
| `0x9e` | `0x00827cc8` | bare | model ASCII default `"H59MA_V1.0"` in `[1..]` |
| `0x9f` | `0x00827b16` | bare | **none** |
| `0xa0` | `0x00827d1a` | bare | status frame (below) |

### 2.1 `0xa0` HighStatus field-by-field

Handler `0x00827d1a` (body `0x191a`):

| Byte | Source | Static meaning |
|---:|---|---|
| 0 | const | `0xa0` |
| 1 | `0x00828fae` → `*(u8*)0x209dd0` | Live session/status flag byte |
| 2 | `0x00832bd2` | `0x23` if mode-class flag set (mode ∈ {`0x11,0x15,0x23,0x28,0x33`}), else `0` |
| 3 | `0x00837b90` | `0x21` if secondary active-state helper non-zero, else `0` |
| 4 | `0x008289a2` | Battery percent, clamped to `0x64` (`*(0x209dbc+0x10)`) |
| 5 | `0x008289bc` high | `(s16)*(0x209dbc+6) >> 8` |
| 6 | same low | `(s16)*(0x209dbc+6) & 0xff` — signed sensor/raw channel |
| 7 | `*(u8*)(0x2088fc + 0x50)` | Persistent blob0 status byte |
| 8 | `*(u16*)(0x2088fc + 0x42) >> 8` | Persistent halfword high |
| 9 | `*(u16*)(0x2088fc + 0x42) & 0xff` | Persistent halfword low |
| 10–14 | 0 | padding |
| 15 | `0x0082b0c4` | additive checksum over 15 bytes |

**Still live-capture:** human labels for bytes 2/3 flag constants and s16 at `0x209dbc+6` (likely raw health/accel channel, not user-facing unit).

---

## 3. Channel-B OTA state machine (end-to-end)

### 3.1 Async low-switch routing (body `0x982e`)

| cmd | Handler body | Flash | Role |
|---:|---:|---:|---|
| `0x01` | `0x8da4` | `0x0082f1a4` | start — callback type `1` status `0` |
| `0x02` | `0x8db6` | `0x0082f1b6` | init metadata (9B) |
| `0x03` | `0x8e40` | `0x0082f240` | data packet |
| `0x04` | `0x8f78` | `0x0082f378` | check/complete |
| `0x05` | `0x8fb4` | `0x0082f3b4` | end/reboot apply path |
| `0x07` | `0x9010` | `0x0082f410` | sub-ack — callback type `7` |
| other low | default NAK `0` | — | |

First-stage dispatcher also runs `ota_dfu_state_machine(1,0)` pre-store for cmds `0x01,02,21,31,35,36,61`.

### 3.2 Runtime state byte (`ota_state+1` near `0x20ada4-0x18`)

| Value | Entered by | Meaning |
|---:|---|---|
| 0 | idle / reset helper `0x9022` | not in OTA write path |
| 1 | start / early init | session opened (start callback) |
| 2 | init metadata OK | ready for first data packet |
| 3 | each accepted data packet | receiving image |
| 4 | check OK (`written == size-0x50`) | verified staged length |
| 5 | end cmd while state==4 | apply/reboot sequence running |

### 3.3 Packet formats

**start `0x01`:** empty payload → unified RSP type `1` status `0` via state callback pointer.

**init `0x02`:** payload length **must be 9**:
```
[0] type ∈ {0x01, 0x04}
[1..4] fileSize u32 LE
[5..6] crc16 u16 LE
[7..8] additive checksum u16 LE
```
NAK-ish callback: wrong length → type `2` status `1`; bad type → type `2` status `2`.  
On success: stores size/crc/cksum, clears written/index, **state=2**, callback type `2` status `0`.

**data `0x03`:**
```
[0..1] packetIndex u16 LE (1-based, must equal last+1)
[2..]  raw bytes (max body after index: 0x600 = 1536)
```
Requires state ∈ {2,3}; else callback type `3` status `3`.  
Packet 1: copy first `0x50` to stack, require word0 == `0x81bdc3e5`, stage from file offset `0x50` at base `0x0084e000`.  
Later packets: sequential flash write, advance `written_bytes`, **state=3**, callback type `3` status `0`.  
Index mismatch / magic fail → error callback (type `3` status `1` path).

**check `0x04`:** requires state `3`; compares `written_bytes` to `expected_size - 0x50`.  
Mismatch → type `4` status `1`; success → **state=4**, type `4` status `0`.  
**Does not** hash or check `image_digest`.

**end `0x05`:** requires state `4` else type `4` status `3`.  
On OK: **state=5**, stop sensors, timers, service reset helpers, reboot path.

**sub-ack `0x07`:** callback type `7` status `0` (progress/side channel).

### 3.4 Size caps

| Cap | Where | Value |
|---|---|---|
| Host OpenWatch | `lib/core/protocol/dfu.dart` | `0xBB8000` (12 MB) — **host only** |
| Per-packet data | OTA data handler | `0x600` bytes after index |
| Pocket size used by app | `dfu.dart` | 1024 raw (valid under 0x600) |
| Body literal `0xBB8000` | body `0x194db` | **not** referenced by OTA handlers (unrelated data island) |

### 3.5 NAK / RSP codes (cross-check `dfu.dart`)

Unified Channel-B frame: `[BC, type, lenLE, crc16, payload…]`.  
OTA status payload first byte = status; `dfu.dart` parses `frame[1]=type`, `payload[0]=status`.

| Type | Name (app) | Typical status |
|---:|---|---|
| 0 | `rspOk` | 0 |
| 1 | `rspDataSize` | 0 after start/init |
| 2 | `rspDataContent` | init errors |
| 3 | `rspCmdStatus` | data pocket |
| 4 | `rspCmdFormat` | check |
| 5 | `rspInner` | end-ish |
| 6 | `rspLowBattery` | refuse OTA |

Compact NAK via `channel_b_send_nak(cmd, code)` (`0x8a00`): one-byte payload = `code`.  
CRC mismatch at first-stage → code **2**. Unknown async cmd → code **0**. Explicit rejects `0x21..0x24` → code **2**.

### 3.6 `dfu.dart` agreement

| App step | Firmware | Match |
|---|---|---|
| Channel-A switch-to-OTA | pre-DFU (outside this SM) | OK |
| `otaStart` empty | `0x01` start | OK |
| init `[01,size,crc,sum]` 9B | exact | OK |
| data `[idx16LE]+raw` 1024 | max 1536 | OK |
| check empty | state3 length check | OK |
| end empty | state4 apply | OK |
| 12 MB reject | host-only | OK (device may accept larger until flash fails) |

---

## 4. File-table field IDs

Formatter `file_format_list_entry` `0x0083105a` / field helper `0x00830fa0`.

Field-id sets at `0x0083121c`:
- Extended (recordType ∈ {4,7,8}): `01 02 03 04 05 06 07 08 09 0d 13`
- Default: `01 02 04 07 08 09`

### fieldId → source record offset / width

| fieldId | Width | Source offset in file record | Notes |
|---:|---:|---:|---|
| `0x01` | 4 | `+0x00` | record id / key word |
| `0x02` | 2 | `+0x12` | |
| `0x03` | 2 | `+0x14` | extended set only |
| `0x04` | 4 | `+0x1c` | |
| `0x05` | 2 | `+0x16` | extended only |
| `0x06` | 2 | `+0x18` | extended only |
| `0x07` | 1 | `+0x07` | |
| `0x08` | 1 | `+0x08` | |
| `0x09` | 1 | `+0x09` | |
| `0x0d` | 1 | `+0x0a` | extended only |
| `0x13` | 4 | `+0x2c` | extended only |

Switch also has latent cases `0x0a/0x0b/0x0c` → 4B at `+0x20/+0x24/+0x28` but those IDs are **not** in the emitted lists.

**User-facing names:** not present as strings; keep generic decode (length-prefixed TLVs).  
Wire record shape unchanged from `h59-file-table/evidence.md`.

---

## 5. `image_digest @0x1c4` — exhaustive negatives

### 5.1 Prior (still true)

- OTA stages bytes from file `0x50` including digest at `0x1c4`.
- Check complete only compares `written == size-0x50`.
- Zero xrefs to digest address or value in app body (`digest-and-boundary`).

### 5.2 New static attempts (this pass)

Containers: v13 `H59MA_1.00.13_251230.bin`, v14 `H59MA_1.00.14_260508.bin`.

**Windows:** full; `from_50`; `from_60`; `from_450`; `0x50..0x1c4`; after digest; digest-zeroed full/`from_50`; header-only.

**Algorithms tried (no matches):**
- MD5 / SHA-1 / SHA-224 / SHA-256 / SHA-384 / SHA-512 (full, prefix32, suffix32)
- HMAC-MD5/SHA1/SHA256 with keys: empty, zero 16/32, header words, magic `0x81bdc3e5`, `const_b4`, model strings, each 4/16-byte header slice
- CRC16-MODBUS / CRC32 / additive sum32 vs digest words
- RSA/ASN.1 structure check: digests are high-entropy 32B, not `0x30` SEQUENCE, not leading-zero PKCS#1 block

**Results:** **zero** hash/HMAC/CRC hits on either build. Digests differ across builds; each appears only at `0x1c4` (no second copy).  
v14 first sha256(full_digest_zero) prefix match length 0 (chance collision only on single bytes).

### 5.3 Bootloader absence

OTA container / app body load at `0x00826400`. No lower-flash ROM image is shipped.  
**Conclusion:** if digest is verified, verification lives **outside** `body.bin` (ROM bootloader / apply stage). Residual static work on digest algorithm **blocked** until bootloader dump.

---

## 6. Channel-A complete opcode inventory (deferred tree)

Dispatcher: `channel_a_dispatch_queued_frame` `0x0082d2dc` (body `0x6edc`).  
Full compare tree dump + handlers: see `inventory.md` §A and `ch-a-dispatch-audit/evidence.md`.

**Opcodes in tree (handled or explicit no-op):**  
`0x01, 0x06, 0x08, 0x0e, 0x14(noop), 0x15, 0x18, 0x1e, 0x25, 0x26, 0x2b, 0x2c, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x43, 0x72, 0x77, 0x7a, 0x7d(noop), 0x81, 0xa1, 0xc6, 0xc7, 0xff`

**vs PROTOCOL §10.2 / GHIDRA deferred list:** all present. Prior “22 handlers” under-count; real distinct handled opcodes = **24 active + 2 no-op + 1 inline multi-sub (`0x08`)**.  
**No tree opcode missing from PROTOCOL tables** after this pass (inventory flags only naming granularity).

Immediate vendor/high path (parallel inventory) adds low switch + high switch + cascade opcodes not deferred.

---

## 7. `qc_app_task` main loop tick order

Entry `0x0082724c` (body `0x0e4c`), create helper `0x008272ec` (`"qc_app"`, stack `0xe00`, prio `1`).

### 7.1 Startup (once)

1. `0x00829444` — init helper  
2. `0x00827202` — secondary init  
3. `*0x208d30 = 3` — service state “running”  
4. optional `0x00832e78` if flag  
5. spin until `0x008289bc()` (sensor s16) non-zero or 100×10ms sleeps  
6. `0x0082994c` + `0x008280fe` + optional `0x0082a460`  
7. `0x008309d4` — late init  
8. enter loop with `timeout = -1`

### 7.2 Steady-state tick (after message)

```
loop:
  os_message_get(queue, -1)          ; block until posted
  if null: continue
  0x0082d2dc  channel_a_dispatch_queued_frame   ; deferred 16B ring
  0x0083304c  secondary ring / notify drain       ; uses state @0x20c044
  0x0082fc0c  channel_b_async_command_processor   ; OTA + Ch-B cmds
  0x00827134  deferred timer / RTC work queue
  0x00829156  live-status / session flag worker   ; touches 0x209dd0
  0x00837cbc  UI/sensor tick A
  0x00837b0e  UI/sensor tick B
  0x00837e78  UI/sensor tick C
  0x00837d5e  UI/sensor tick D
  goto loop
```

**Order invariant:** Channel-A deferred drain **before** Channel-B async; both before UI/sensor maintenance ticks.

---

## 8. Live-capture-only residual list

1. ECG/PPG notify opcodes (absent v14 — confirm on device)  
2. Human labels for `0xa0` bytes 2/3/5–6  
3. BP compact-byte ↔ cuff mmHg correlation  
4. `@RequiresSignature` cloud endpoint set  
5. `image_digest` algorithm (needs bootloader)  
6. File-table fieldId product names  
7. Exact `0x0c` 7-byte BP setting field semantics  
8. Channel-B sleep slot units (partially open from prior notes)

---

## 9. Confidence

| Finding | Confidence |
|---|---|
| Low-range wire layouts | High |
| High `0x91..0xa0` shapes | High |
| `0xa0` byte sources | High (labels Medium) |
| OTA states + packets | High |
| File fieldId offsets | High (names none) |
| Digest negatives | High |
| Deferred opcode tree complete | High |
| qc_app tick order | High |
