# H59MA v14 Firmware — Ghidra Decompilation Notes

> Generated from `firmwares/_re/v14/body.bin` loaded in Ghidra at base `0x00826400`.
> Language: `ARM:LE:32:Cortex`, raw binary, ~136 KB, ~1139 functions.

---

## 1. Entry Point & Boot

| Address | Function | Notes |
|---|---|---|
| `0x00826400` | `entry` | Cortex-M trampoline: `ldr r0,[0x00826404]; bx r0` |
| `0x0082643c` | reset handler | Sets SP, calls system init, then `app_main_task` (`0x00826988`) |

The vector table at `0x00826400` contains the initial SP, reset handler, and ISR pointers.

---

## 2. Channel B — Large-Data / OTA / File Channel

Channel B uses a framed protocol over GATT notify/write:

```
byte 0      magic 0xBC
byte 1      cmd id
byte 2..3   payload length, little-endian u16
byte 4..5   payload CRC-16/MODBUS, little-endian u16
byte 6..    payload bytes
```

### Key functions

| Address | Function | Role |
|---|---|---|
| `0x0082efea` | `FUN_0082efea` | **Parser / fragment reassembly** |
| `0x0082eee6` | `FUN_0082eee6` | **Dispatcher** after full frame received |
| `0x0082fc0c` | `FUN_0082fc0c` | **Async command processor** (runs from state stored by `FUN_0082f4fa`) |
| `0x0082f114` | `FUN_0082f114` | **CRC-16/MODBUS** (init `0xFFFF`, poly `0xA001`) |
| `0x0082ece0` | `FUN_0082ece0` | **Frame builder / sender** (queues `0xBC` notifications) |
| `0x0082ee00` | `FUN_0082ee00` | **ACK/NAK sender** |
| `0x0082f098` | `FUN_0082f098` | Starts 2000 ms fragment timeout timer (`m_ble_packet_timer_id`) |
| `0x0082f4fa` | `FUN_0082f4fa` | Stores parsed Channel B command for asynchronous consumption |
| `0x0082fe52` | `FUN_0082fe52` | OTA state machine (DFU) |

### Parser behavior (`FUN_0082efea`)

- State byte at `DAT_0082f0f0 + 0xb`:
  - `0`: waiting for first fragment.
    - Accepts if `len > 5` and `buf[0] == 0xBC`.
    - Saves `cmd = buf[1]`, `length = LE16(buf[2..3])`, `crc = LE16(buf[4..5])`, copies `buf[6..]`.
    - If `length <= received`, calls dispatcher.
  - `1`: continuation. Appends payload until `accumulated >= length`.

### Dispatcher behavior (`FUN_0082eee6`)

1. Computes CRC over assembled payload with `FUN_0082f114`.
2. If CRC mismatch → sends NAK (`FUN_0082ee00(cmd, 2)`).
3. Direct routes for OTA commands:
   - `0x01`, `0x02`, `0x21`, `0x31`, `0x35`, `0x36`, `0x61` → `FUN_0082fe52(1, 0)`
   - `0x10`, `0x46` → skip (handled elsewhere / no direct dispatch)
4. All other commands → `FUN_0082f4fa(cmd, payload, length)` for asynchronous consumption.

### Async processor (`FUN_0082fc0c`)

Consumes the state saved by `FUN_0082f4fa` (`cmd` at offset `+1`, payload ptr at `+4`, length at `+0xc`).

The dispatch is a hybrid: low cmds `0x00..0x10` go through a switch8
table at `0x82fc2f` (base, `0x12` entries: `0x2e, 0x5f, 0x63, 0x69, 0x6d,
0x71, 0x2e, 0x75, 0x2e..0x2e`); cmds `0x11..0x5a` use a cascade of
`cmp/beq` branches. On exit the handler clears `state[+1]` so the slot
is reusable.

| Cmd | Handler | Notes |
|---|---|---|
| `0x01` | `FUN_0082f1a4` (table offset 0x5f) | OTA start ack — calls state callback `(1, 0)` |
| `0x02` | `FUN_0082f1b6` (table offset 0x63) | OTA init — expects 9-byte payload, sub-cmd `0x01`/`0x04`; stores image size and metadata; sets OTA state to `2` |
| `0x03` | `FUN_0082f240` (table offset 0x69) | OTA data packet — reassembles image, validates first 0x50 bytes, copies a 32-byte digest, writes to flash |
| `0x04` | `FUN_0082f378` (table offset 0x6d) | OTA check — validates state `3` and accumulated size matches expected |
| `0x05` | `FUN_0082f3b4` (table offset 0x71) | OTA end — finalizes, resets sensors/BLE, reboots after delays |
| `0x06` | — | falls into the table's default `0x2e` slot — NAK with code 0 |
| `0x07` | `FUN_0082f410` (table offset 0x75) | OTA sub-ack — calls state callback `(7, 0)` |
| `0x08..0x10` | — | default slot — NAK with code 0 |
| `0x11` | `FUN_0082f5a2(payload[0])` | Read sleep summary — see §2.1 |
| `0x12` | `FUN_0082f50c()` | Read detailed sleep data — see §2.2 |
| `0x13` | — | no-op (skipped) |
| `0x21`, `0x22`, `0x23`, `0x24` | `FUN_0082ee00(cmd, 2)` | ACK with code `2` (intentionally rejected at this layer) |
| `0x27` | `FUN_0082fada(payload[0], payload[1])` | Read sleep records — see §2.3 |
| `0x29`, `0x3b` | — | no-op (skipped) |
| `0x2a` | `FUN_00833bbc(payload[0])` | Read activity/sport summary — see §2.4 |
| `0x2c` | `FUN_0082f8ec()` | Alarm read/write — see §2.5 |
| `0x41` | `FUN_008311b8(0x41, payload, length)` | File list — see §2.6 |
| `0x43`, `0x46` | `FUN_008311b8(cmd, payload)` | File init / file delete (same handler) — see §2.6 |
| `0x47` | `FUN_008347fa(payload[0])` | no-op |
| `0x4b` | `FUN_00830460(payload[0])` | no-op |
| `0x5a` | `FUN_0082f6ec(payload)` | Device info/config — see §2.7 |

Unrecognized commands fall through to `FUN_0082ee00(cmd, 0)` (NAK code `0`).

#### 2.1 Sleep summary (`FUN_0082f5a2`)

Input: `payload[0]` is the day offset (0 = today, 1 = yesterday, …).
Effective day is `current_day - payload[0]`. The handler reads 100 B
from the sleep-summary store via `FUN_008318c2(day, buf)` and emits a
0x65-byte (101 B) Channel-B frame:

```
byte 0     presence_byte (the byte pointed at by *(DAT_0082f894 + 4))
byte 1..100 100-byte summary (e.g. totals, deep/light/REM minutes,
              avg HR, breath rate — exact layout recovered only after
              linking with the producer side)
```

#### 2.2 Detailed sleep (`FUN_0082f50c`)

Uses the day-index byte at `*(DAT_0082f894 + 4)` and an aux size at
`DAT_0082f89c` (typically `0x130`). Two-phase build:

1. If `FUN_008318b0(day) == 0` (no record): `memset(target, 0, DAT_0082f89c)` (zero-fill).
   Otherwise call the delayed init helper `func_0x000002a8` (probably a flash-read wrapper).
2. If the day-index byte is `0` (record not ready), send a NAK via
   `FUN_0082ee00(0x12, day_index_byte)` instead of a payload.
3. Otherwise the response is 0x121 B: byte 0 = day_index_byte, bytes
   1..0x120 = a 0x120-byte slice from `auStack_52c + DAT_0082f8a0`
   (i.e. a 0x120-byte "detailed" window whose offset is the
   sleep-context base).

#### 2.3 Sleep records (`FUN_0082fada`)

Inputs: `param_1` (clamped to 6) = day offset; `param_2` = record-type
filter. Two parallel passes always run, regardless of `param_2`:

- Nap pass (`param_2 == 1`): reads records via `FUN_00831908(day, buf)`.
  Emits one Channel-B `0x3E` frame (header + nap records).
- Night-sleep pass (always): reads via `FUN_008318c2(day, buf)`.
  Emits one Channel-B `0x27` frame (header + night records).

Each emitted record (6-byte header + score bytes + label bytes) is
laid out as:

```
byte 0       day_delta   (current_day - source_day, capped)
byte 1       header      (record_count * 2 + 4)
byte 2..3    start_time  (hour, minute) — u16 min-of-day split
byte 4..5    end_time    (hour, minute)
byte 6..N    per-record score bytes (count = record_count)
```

The very first byte of the response is the number of records actually
written (`cVar8` accumulator).

#### 2.4 Activity / sport summary (`FUN_00833bbc`)

Input: `payload[0]` is the day offset (clamped to 2, max 3 days
back). Iterates from `current_day` down to `current_day - offset`,
calling `FUN_00833b42(day, buf)` (returns 0 if no data). For every
day with data, emits a 0x31-byte entry:

```
byte 0       day_offset
byte 1..0x30 48 bytes activity summary (steps, distance, calories,
                per-sport mode stats; the field meaning is owned by
                the producer in `FUN_00833b42`)
```

The total Channel-B frame uses cmd `0x2A` and a length up to
`0x31 * 3 = 0x93` bytes.

#### 2.5 Alarm read/write (`FUN_0082f8ec`)

Sub-cmd at `payload[0]`:

| Sub | Action |
|---|---|
| `0x01` | Read: pulls `FUN_0082a9c2(count, ...)` and re-emits up to 10 alarms. Each alarm is a 0x29-byte record: `[len, id, hour, minute, day_bitmap(7 B), label(N)]` with `(len & 0x7F) ∈ [4, 0x22]`. Response is `1 + count * 0x29` bytes, cmd `0x2C`. |
| `0x02` | Write: pulls count from `payload[1]`, clamps to 10, validates per-alarm `(len & 0x7F) ∈ [4, 0x24]`, calls `FUN_0082a9b0(record)`. Response is 1 byte (`0x02`) ack, cmd `0x2C`. |
| other | no-op (response = 1 byte) |

#### 2.6 File commands (`FUN_008311b8`)

Sub-handler selected by `cmd`:

| Cmd | Action |
|---|---|
| `0x41` | List: copies 4 B of context from `payload`, walks `FUN_008313ba` (up to 10 entries) and formats each via `FUN_0083105a`. Response uses cmd **`0x42`** (note: not `0x41`) — first byte is the file count. |
| `0x43` | Init: `FUN_008310c8(payload)` — no response payload. |
| `0x46` | Same body as `0x43` (file delete) — gated by caller's length check. |

#### 2.7 Device info / config (`FUN_0082f6ec`)

Sub-cmd at `payload[0]`:

| Sub | Action |
|---|---|
| `0x01` | Read info: builds a TLV list from a capability bitmap at `DAT_0082f8a4+0x15/0x16`. Each present feature calls `FUN_0082f5e6(slot_id, src, src_len, dst)` and accumulates length into `uVar7`. Six slots, with strings at fixed offsets: `H59MAX`, `H59MA_V1_0`, `H59MA__`, `1_00_14_`, `260508`. Response is cmd `0x5A`, payload = `[0x01, 0x01, 0x06, ...tlv...]`. |
| `0x02` | Write: iterates payload TLVs, calling `FUN_0082f5fa(slot_id, src)` per entry, then `FUN_008294cc` and `func_0x0000029c(1, 0xd0)` (a one-shot timer). |
| `0x03` | Read version strings: emits 6 slots — `s_H59MAX__0082f8a8` (7 B), `s_H59MAX__0082f8a8` (7 B), `s_H59MA_V1_0_0082f8b0` (10 B), `s_H59MA__0082f8bc` (6 B), `s_1_00_14__0082f8c4` (8 B), `s_260508_0082fcb4` (6 B). |
| `0x04` | Reset: `memset(DAT_0082f8a4 - 0x46, 0, 100)` and `FUN_008294cc()`. |
| other | Response = `[0x5A, 0x00, 0x00]` (3 B, status 0). |

The 6 version string slots are the *only* string literals referenced
in this dispatcher; the response bytes for cmd `0x03` are exactly the
constants visible in `firmwares/_re/strings-mining/`.

### CRC-16/MODBUS (`FUN_0082f114`)

Disassembly confirms standard MODBUS CRC:

```asm
push {r4,r5,r6,lr}
mov  r4, r0           ; buf
ldr  r0, [0x0082f154] ; initial 0xFFFF
movs r2, #0           ; i
ldr  r5, [0x0082f158] ; CRC table base
loop:
ldrb r6, [r4, r2]
uxtb r3, r0
eors r3, r6
lsls r3, r3, #1
ldrh r3, [r5, r3]
lsrs r0, r0, #8
eors r0, r3
adds r2, r2, #1
cmp  r2, r1
blt  loop
pop  {r4,r5,r6,pc}
```

---

## 3. Channel A — 16-Byte Command Channel

Channel A frames are fixed 16 bytes. The main command dispatcher is `FUN_0082d2dc` **in the firmware** — this routine processes a circular queue of incoming 16-byte frames, reads the opcode at offset `2`, and dispatches to a handler. Earlier notes in `R2_ANALYSIS.md`/`PROTOCOL.md` claimed Channel-A dispatch was APK-only; that claim is incorrect for v14.

### Main dispatcher (`FUN_0082d2dc`)

Processes a circular queue of incoming 16-byte frames (`DAT_0082d440 + 0x14` ring). For each frame it reads the opcode at offset `2` and dispatches to a handler.

### Opcode → handler map

| Opcode | Dart name (from `lib/core/protocol/opcodes.dart`) | Handler address | Handler summary |
|---|---|---|---|
| `0x01` | `setTime` | `0x0082bb4e` | Converts BCD date/time fields, updates RTC, sends `0x2f` packet-length notify, then `0x01` ack. |
| `0x06` | `dnd` | `0x0082d298` | Sub-opcode `0x01` reads DND state, `0x02` sets it. Builds response and sends via `FUN_0082ebdc`. |
| `0x08` | *(special)* | `0x00827516`, `0x008275b6`, `0x00827ba6`, `0x008280fe` | Camera/find-device/long-press branch: checks sub-byte and routes to motor/vibrate/screen routines. |
| `0x0e` | `bpReadConform` | `0x0082cb28` | If sub-byte `0` → `FUN_00834410()` + `FUN_0082c0a4()`. |
| `0x15` | `readHeartRate` | `0x0082cf48` | Reads heart-rate record by index; returns `0x15` multi-frame data or `0xff15` error. |
| `0x18` | `displayClock` | `0x0082ccb6` | Sets watch-face / clock display; handles string labels and numbered styles. |
| `0x1e` | `realTimeHeartRate` | `0x0082d20c` | Sub `0x01` starts 60s HR measurement, `0x02` stops, `0x03` resets timer. |
| `0x25` | `setSitLong` | `0x0082d284` | Calls sedentary config routines, acks `0x25`. |
| `0x26` | `readSitLong` | `0x0082d258` | Reads sedentary config, sends `0x26` response. |
| `0x2b` | `menstruation` (mixture container) | `0x0082ba54` | Sub `0x01`/`0x02` read/write mixture data; cycle-phase detector + notification sender — see §3.1. |
| `0x2c` | `bloodOxygenSetting` | `0x0082d1c2` | Sub `0x01` reads SpO2 setting, `0x02` writes it. |
| `0x37` | `pressureSetting` | `0x0082caa6` | Reads/sets pressure config; uses `FUN_008344fe`. |
| `0x38` | `pressure` | `0x0082ca54` | Sub `0x01` reads pressure value, else sets pressure unit. |
| `0x39` | `hrvSetting` | `0x0082c9da` | Reads/sets HRV config; uses `FUN_0083468e`. |
| `0x3a` | `sugarLipidsSetting` | `0x0082cc1e` | Sub `0x03`/`0x04` read/write sugar/lipids settings. |
| `0x3b` | `uvSetting` / `touchControl` | `0x0082cbc8` | Read/write UV/touch config byte at `DAT_0082cfe8 + 8`. |
| `0x43` | `readDetailSport` | `0x0082d034` | Reads detailed sport records by date range, sends multi-frame `0x43` responses. |
| `0x72` | `pushMsgUint` | `0x00829e92` | Buffers a notification/emoji Unicode string for display; UTF-8 length parsing. |
| `0x77` | `phoneSport` | `0x0082ce0c` | Jump-table dispatch on sub-byte. |
| `0x7a` | `muslim` | `0x0082cb3a` | Sub `0x01` reads Muslim prayer config, `0x02 0x01` resets it. |
| `0x81` | — | `0x0082cdac` | Stores 6-byte config chunk and calls `FUN_00840568` (flash/config write). |
| `0xa1` | — | `0x00827f5c` | Factory/test mode commands (`0x01`–`0x06`): reset, read logs, power off, etc. |
| `0xc6` | `restoreKey` | special | Reboot sequence: clears state, resets BLE, restarts main task. |
| `0xc7` | — | `0x00832ebc` | Vibration/motor pattern player (`#`/`D` branches). |
| `0xff` | — | `0x0082cde8` | Factory reset: if payload is `"fff"`, wipes `0xa4` bytes of config. |

### Common response path

Most handlers build a 16-byte response buffer, compute an additive checksum with `FUN_0082b0c4`, and send it via `FUN_0082ebdc`:

| Address | Function | Role |
|---|---|---|
| `0x0082b0c4` | `FUN_0082b0c4` | Additive byte checksum (sum of first 15 bytes → byte 15) |
| `0x0082ebdc` | `FUN_0082ebdc` | Queue 16-byte response into Channel A notify ring |
| `0x0082b938` | `FUN_0082b938` | Send a long response fragmented into 14-byte chunks |
| `0x0082c988` | `FUN_0082c988` | Stream large data for opcodes `0x37`, `0x39`, `0x7a` |

`FUN_0082b986(opcode, isNotify)` sends a simple 1-byte opcode response (with `0x80` flag for notify-only opcodes).

### Opcode `0x77` `phoneSport` sub-command dispatch (`FUN_0082ce0c`)

`FUN_0082ce0c` reads `subData[0]` (frame byte `3`) and dispatches via `__ARM_common_switch8` with max index `6`:

| Sub-byte | Handler | Notes |
|---|---|---|
| `0x00`, `0x06` | `FUN_0082cede` | Default ack — builds `0x77` response with checksum |
| `0x01` | `FUN_0082ce2a` | Start/finish sport session; zeros `DAT_0082cff4`; calls `FUN_00828af4`, `FUN_00830c7e`; arms a 1000 ms timer |
| `0x02` | `FUN_0082ce64` | Calls `FUN_00830cb2`; sets `DAT_0082cff4+1` flag |
| `0x03` | `FUN_0082ce72` | Calls `FUN_00830cd4`; sets `DAT_0082cff4+1` flag |
| `0x04` | `FUN_0082ce80` | Cancels timer (`_DAT_0082cffc`); calls `FUN_00830c7e` |
| `0x05` | `FUN_0082ce96` | GPS/position delta: reads two 3-byte little-endian values from `subData[2..6]` and `subData[6..10]`, updates cumulative distance/step counters |

The helper functions `FUN_00830c7e`, `FUN_00830cb2`, `FUN_00830cd4` live in the step-counter / sport-motion library (`vc_SportMotion_Int`).

### Opcode `0xa1` factory/test mode (`FUN_00827f5c`)

`subData[0]` selects the test action:

| Sub-byte | Action |
|---|---|
| `0x01` | Full reset: stop sensors/motor, save current state to RAM context, clear step data, start 1000 ms timer, power off / enter DLPS |
| `0x02` | Restore saved state from RAM context to sensor modules |
| `0x03` | Power off / enter DLPS immediately |
| `0x04` | Start HR measurement with `0x800` mode |
| `0x05` | Stop HR measurement |
| `0x06` | Save current state and then power off |
| other | Send `0xffa1` error response |

### 3.1 Opcode `0x2b` menstruation / mixture container

The `0x2b` handler (`FUN_0082ba54`) backs a 16-byte persistent record on the
device. The record is anchored at a runtime pointer stored in the literal
pool slot `DAT_0082b0b8` (value `0x00208c7c`). Functions that touch the
record refer to it via negative or positive byte offsets relative to that
pointer; in the layout below **byte 0** of the record lives at
`DAT_0082b0b8 - 6` (= `0x00208c76`).

#### Record layout (`mixture_state_t`, 16 bytes)

| Off | Field | Size | Set by | Read by |
|---:|---|---:|---|---|
| 0 | `state_flag` | 1 | `FUN_0082aee4` writes `0xCA` on a successful write | `FUN_0082b078` clears 16 B if `!= 0xCA` |
| 1..3 | `start_date_bcd[3]` | 3 | copied from `req[2..4]` | copied into `rsp[0..2]` |
| 4..5 | `start_day_pair` (u16) | 2 | `= current_day - req[5]` (signed overflow wrap) | low byte returned as `rsp[3] = current_day - record[4]` |
| 6..7 | `start_month_pair` (u16) | 2 | `= current_month - req[6]` | low byte returned as `rsp[4] = current_month - record[6]` |
| 8..12 | `period_data[5]` | 5 | copied from `req[7..11]` | copied into `rsp[5..9]` |
| 13..15 | (padding) | 3 | left zero | always zero |

The `state_flag` doubles as a "record present" sentinel: any caller that
sees `state_flag != 0xCA` must treat the record as uninitialised.

#### Sub-opcode dispatch (`FUN_0082ba54`)

`req[1]` selects the action:

| Sub | Action |
|---|---|
| `0x01` | Read: calls `FUN_0082af28(rsp)`, which copies the record into `rsp[0..9]` and leaves `rsp[10..14]` zeroed. `rsp[0]` ends up holding `start_date_bcd[0]` (the opcode byte the caller pre-stamped is overwritten by the read — firmware quirk, see §3.1.1). |
| `0x02` | Write: calls `FUN_0082aee4(req + 2)` with the 10-byte payload starting at the second byte after the sub-opcode. After copying, it sets `state_flag = 0xCA`. The write response reuses the cleared 16-byte buffer (only `rsp[0] = 0x2B` is set), so the host receives an empty `0x2B` ack. |
| other | No-op: response is a 16-byte buffer with only `rsp[0] = 0x2B` set. |

In all three cases the handler finishes by stamping `rsp[15] = FUN_0082b0c4(rsp, 0xf)` (additive byte checksum) and queues the frame via `FUN_0082ebdc`.

#### 3.1.1 Read-path quirk

The handler pre-fills the response with `local = {0x2B, 0, 0, 0, 0, …, 0}`
(16 B on stack via `push {r0-r3, r4, lr}`). `FUN_0082af28` then calls
`memcpy(rsp, record + 1, 3)`, which **clobbers `rsp[0]`** with
`start_date_bcd[0]`. The remaining 14 bytes are populated correctly
(`rsp[3..4]` are the truncated day/month deltas, `rsp[5..9]` are
`period_data`, `rsp[10..14]` are zero). The byte-0 overwrite appears to
be a long-standing firmware bug: a host that decodes `0x2b` strictly by
"first byte == 0x2B" will reject every read response. Practical decoders
should treat the *whole frame* (including the opaque `rsp[0]` value) as
the record payload and re-stamp `rsp[0] = 0x2B` after copy.

#### Cycle-phase detector (`FUN_0082af64`)

A pure helper that classifies the current cycle phase for a given
day-offset input. Return values:

| Return | Meaning |
|---:|---|
| `3` | Unset (`start_date_bcd[0] == 0` or `start_date_bcd[2] == 0`) |
| `2` | Early phase — `day_offset + 1 <= start_date_bcd[1]` |
| `1` | Mid phase — `(start_date_bcd[2] - (day_offset + 1) - 9) ∈ [0, 9]` |
| `0` | Late phase — otherwise |

`day_offset` is computed as
`(start_date_bcd[2] + current_month + arg) - start_day_pair`; the
comparison `start_date_bcd[1]` therefore reads as the cycle length in
days (typical: 28).

#### Phase-transition notifier (`FUN_0082b01e`, `FUN_0082b090`)

`FUN_0082b01e` is called from the main-loop tick `FUN_00827134` (after
the daily `*pcVar2 == '\x03'` check). It compares the *current* phase
(`thunk_FUN_0082af64(record[3])`) with the *previous* phase
(`thunk_FUN_0082af64(record[3] - 1)` and `thunk_FUN_0082af64(record[4] - 1)`),
and on a 0→1 or 1→2 transition invokes `FUN_0082b090(phase)` which
fires a motor+UI alert (`FUN_0082a5b2(5)` + `FUN_0082994c(0x12, 1, 3, 10)`)
provided the user is on the home screen (`FUN_0082a826() == 0`).

#### Lazy initializer (`FUN_0082b078`)

On the first reference after boot, `FUN_0082b078` checks
`record[0] != 0xCA` and, if so, zeros the full 16-byte record. This
guarantees the "unset → return 3" branch in `FUN_0082af64` works
without needing an explicit factory-reset path.


---

## 4. ANCS (Apple Notification Center Service)

| Address | Function | Role |
|---|---|---|
| `0x00839ac4` | `FUN_00839ac4` | Sends ANCS data over notify char |
| `0x00839e4e` | `FUN_00839e4e` | `ancs_add_client` — registers ANCS client, allocates client state |
| `0x0083a116` | `FUN_0083a116` | `ancs_client_cb` — handles ANCS events (`0` connect, `1` notification, `2` data, `3` disconnect) |
| `0x00839fee` | `FUN_00839fee` | Stores parsed notification source data |

The watch implements an ANCS client so iOS notifications can be pushed to the screen via opcode `0x72`.

---

## 5. OTA / DFU

| Address | Function | Role |
|---|---|---|
| `0x00840724` | `FUN_00840724` | OTA signature check — compares first 4 bytes of image to magic `0x8721bee2` (stored at `DAT_00840744`); logs `"wrong signature! Read %8X != Requried %8X"` |
| `0x0082fe52` | `FUN_0082fe52` | OTA/DFU state machine driven by Channel B cmd ids |
| `0x0082f160` | `FUN_0082f160` | Starts a one-shot timer (used during reboot/OTA) |
| `0x0082f1a4` | `FUN_0082f1a4` | OTA start ack |
| `0x0082f1b6` | `FUN_0082f1b6` | OTA init — parses image header, stores size/digest metadata |
| `0x0082f240` | `FUN_0082f240` | OTA data — reassembles and writes image, validates a 32-byte digest block |
| `0x0082f378` | `FUN_0082f378` | OTA check — validates completion and size |
| `0x0082f3b4` | `FUN_0082f3b4` | OTA end — reboots device |
| `0x0082f410` | `FUN_0082f410` | OTA sub-ack |

The 32-byte OTA digest buffer is prepared in `FUN_0082f240` but the hashing algorithm itself is not located in the firmware body; it may live in the bootloader or be computed by the host tool.

---

## 6. Power Management & System

| Address | Function | Role |
|---|---|---|
| `0x0082a144` | `FUN_0082a144` | Button/DLPS init — sets up long-press, debounce, DLPS timers |
| `0x008275d8` | `FUN_008275d8` | System reset / re-initialize: stops sensors, resets BLE, restarts main task |
| `0x0082a460` | `FUN_0082a460` | Delays via a 1000 ms timer (used in reboot paths) |
| `0x008267cc` | `FUN_008267cc` | PRNG — linear-feedback style random generator |
| `0x0082ebdc` | `FUN_0082ebdc` | Queue manager for Channel A notifications |
| `0x0082eb8a` | `FUN_0082eb8a` | Kicks BLE notify transmission |

---

## 7. Health / Sensor Modules

| Address | Function | Role |
|---|---|---|
| `0x00833770` | `FUN_00833770` | HR module dispatcher (refers to `hr_module.c`); branches on sub-command 0–3 |
| `0x00833334` | `FUN_00833334` | Accelerometer / LIS3DH SPI dispatcher |

Strings confirm additional algorithm libraries: `VC_HRV_16Bit_integration_6.0_addRMSSD`, `spo2_VC30F_S_int_limit_ed01`, `lib_BIODetect_V14_1`, `vc_SportMotion_Int`.

---

## 8. Vendor `0xFEE7` GATT Service — Active Protocol Role

The `0xFEE7` vendor service is **not** table decoration. It is registered during BLE initialization (`FUN_0082e464` → `FUN_0082e8ec`) using an attribute table at base `0x00845604` (size `0xa8`). Three handler pointers are active in the GATT records:

| Handler | Address | Role |
|---|---|---|
| `FUN_0082e850` | `0x0082e850` | Read handler — returns a runtime buffer pointed to by `DAT_0082e934` (length stored at `buffer[-2]`) |
| `FUN_0082e87a` | `0x0082e87a` | Write/notify handler — GATT event `2` routes to the protocol dispatcher `FUN_0082c944` |
| `FUN_0082e8ce` | `0x0082e8ce` | CCCD/log handler — only emits debug traces |

The write handler is the protocol entry point.

### Wire format

`FUN_0082c944` expects 16-byte writes and uses the same framing as Channel A:

```
byte 0      opcode
byte 1..14  payload / parameters
byte 15     additive checksum (sum of bytes 0..14)
```

If `opcode` is not `'C'` (`0x43`) or `'H'` (`0x48`) the firmware first resets a keep-alive timer (`FUN_0082eebe`), then dispatches on the opcode.

Responses are built with `FUN_0082b0c4` (additive checksum) and queued through `FUN_0082ebdc` / `FUN_0082eb8a` into the same 16-byte notify ring used by Channel A. Many commands are simply copied into a deferred command ring (`FUN_0082be64`) and processed later.

### Opcode → handler map (from `FUN_0082c944`)

Immediate / explicitly routed opcodes:

| Opcode | Handler | Notes |
|---|---|---|
| `0x36` | `FUN_0082c112` | Heart-rate related read/set |
| `0x3c` | `FUN_0082c50e` | Returns fixed capability block `[0x3c,0,0x40,0xa0,0x20,...]` |
| `0x3e` | `FUN_0082c550` | SpO2 / blood-oxygen related read/set |
| `0x48` `'H'` | `FUN_0082bf40` | Handshake response — sends 15-byte device-info block |
| `0x50` `'P'` | inline | Calls `FUN_0082994c(0x14,0x10,1,0x19)` + `FUN_0082a5c8(8)` (alert/motor) |
| `0x51` `'Q'` | `FUN_0082c5b8` | "Find phone" / alert trigger; arms pattern when `payload[1]==1` |
| `0x60` | `FUN_0082be90` | |
| `0x61` `'a'` | `FUN_0082bee6` | Status response (battery / daily counters) |
| `0x69` `'i'` | `FUN_0082c2f4` | Multi-step mode control (start/stop/cancel of a remote feature) |
| `0x6a` `'j'` | `FUN_0082c1e2` | Continuation of `0x69` mode control |
| `0x90` | `FUN_00827ad2` | Echo `[0x90]` |
| `0x91` | `FUN_00827aee` | Echo `[0x91]` |
| `0x92` | `FUN_00827b14` | |
| `0x93` | `FUN_00827c4a` | |
| `0x94` | `FUN_00827b2e` | |
| `0x95` | `FUN_00827b54` | |
| `0x96` | `FUN_00827b7c` | Sends `[0x96,0,0,0x96,...]` and resets state |
| `0x97` | `FUN_00827ba4` | |
| `0x98` | `FUN_00827be6` | |
| `0x99` | `FUN_00827bea` | |
| `0x9a` | `FUN_00827bec` | |
| `0x9b` | `FUN_00827bf0` | |
| `0x9c` | `FUN_00827c1e` | |
| `0x9e` | `FUN_00827cc8` | |
| `0x9f` | `FUN_00827d1a` | |
| `0xa0` | `FUN_00827b16` | |
| `0xbf` | `FUN_0082ba94` | |
| `0xc0` | `FUN_0082bb0c` | |
| `0xc1` | `FUN_008337fa` + `FUN_0082b938` | Sends a long/fragmented response |
| `0xc3` | `FUN_0082fe52` | Drives the OTA/DFU state machine (`param[2]==1` also calls `FUN_0082dfde`) |
| `0xc4` | `FUN_00830462` | No-op in firmware |
| `0xc5` | — | Sets `DAT_0082caec[3]` from `param[1]` |
| `0xc8` | — | Sets `DAT_0082caec[4]` from `param[1]` |
| `0xc9` | — | Sets `DAT_0082caec[5] = param[1]` |
| `0xcd` | `FUN_0082be12` | Stores a 16-bit value / alarm-like setting |
| `0xce` | `FUN_0082bcde` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) |
| `0xfe` | `FUN_00844214` | Builds a vibration pattern from a duration argument |

Opcodes `0x2b`, `0x37`, `0x38`, `0x3a`, `0x3b`, `0x43`, `0x72`, `0x77`, `0x7a`, `0x7d`, `0x81`, `0xa1`, `0xc6`, `0xc7`, `0xff` and most of the `0x00`–`0x2a` switch table are routed to `FUN_0082be64`, which copies the frame into a deferred 16-byte command ring. Opcodes `0x7b`, `0xb0`, `0xc2`, `0xcc`, `0xf0`, `0xf1` are explicit no-ops. Unrecognized opcodes fall through to `FUN_0082bcba`.

### Take-away

The `0xFEE7` service carries a parallel 16-byte command channel that overlaps some Channel-A opcodes (e.g. `0x48`, `0x50`, `0x51`, `0x69`, `0x6a`, `0x3c`, `0x3e`) and adds vendor-specific commands (`0x90`–`0x9f`, `0xce`, `0xfe`). The OpenWatch host code should treat it as a second command path rather than a passive discovery UUID.

---

## 9. Notable Data & Globals

| Global | Inferred role |
|---|---|
| `DAT_0082d440` | Channel A command queue state |
| `DAT_0082f0f0` | Channel B reassembly buffer state |
| `DAT_0082edb8` | Channel A notify ring buffer state |
| `DAT_00830120` / `DAT_00830124` | OTA/DFU state structure |
| `DAT_0082b0b8` | Current time / date shared buffer |
| `DAT_00827e8c` | Vibration/motor mode |
| `DAT_0082cfe8` | Config block base (UV, display, etc.) |
| `DAT_0082fcbc` | Channel B async processor state (cmd, payload ptr, length) |
| `DAT_0082f458` | OTA state / context pointer base |
| `DAT_0082f894` | Sleep data context pointer |
| `DAT_0082f8a4` | Device info context pointer |

---

## 10. Open Questions / Next Steps

1. ~~Recover the exact meaning of opcode `0x2b` mixture container fields.~~ **Resolved** — see §3.1. The 16-byte `mixture_state_t` is now fully decoded; remaining unknowns are semantic (BCD field interpretation, period-data byte meanings).
2. Identify the 32-byte `image_digest` algorithm used for OTA and the container header digest at `0x1c4`. No SHA-256 constants were found in the body; it may be computed by the bootloader or host tool.
3. ~~Determine whether the `0xFEE7` vendor service has any active protocol role in the firmware.~~ **Resolved** — see §8; it implements a second 16-byte command channel.
