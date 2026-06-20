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
| `0x01` | `setTime` | `0x0082bb4e` | Converts BCD date/time fields, updates RTC, sends `0x2f` packet-length notify, then a 14-byte `0x01` ack — see §3.4. |
| `0x06` | `dnd` | `0x0082d298` | Sub-opcode `0x01` reads DND state, `0x02` sets it — see §3.7. |
| `0x08` | *(special)* | `0x00827516`, `0x008275b6`, `0x00827ba6`, `0x008280fe` | Camera/find-device/long-press branch — see §3.15. |
| `0x0e` | `bpReadConform` | `0x0082cb28` | If sub-byte `0` → `FUN_00834410()` + `FUN_0082c0a4()` — see §3.19. |
| `0x15` | `readHeartRate` | `0x0082cf48` | Reads heart-rate record by index; returns `0x15` multi-frame data or `0xff15` error — see §3.12. |
| `0x18` | `displayClock` | `0x0082ccb6` | Sets watch-face / clock display — see §3.5. |
| `0x1e` | `realTimeHeartRate` | `0x0082d20c` | Sub `0x01` starts 60s HR measurement, `0x02` stops, `0x03` resets timer — see §3.13. |
| `0x25` | `setSitLong` | `0x0082d284` | Writes sedentary config — see §3.9. |
| `0x26` | `readSitLong` | `0x0082d258` | Reads sedentary config — see §3.9. |
| `0x2b` | `menstruation` (mixture container) | `0x0082ba54` | Sub `0x01`/`0x02` read/write mixture data; cycle-phase detector + notification sender — see §3.1. |
| `0x2c` | `bloodOxygenSetting` | `0x0082d1c2` | Sub `0x01` reads SpO2 setting, `0x02` writes it — see §3.10. |
| `0x37` | `pressureSetting` | `0x0082caa6` | Reads/sets pressure config; uses `FUN_008344fe` — see §3.20. |
| `0x38` | `pressure` | `0x0082ca54` | Sub `0x01` reads pressure value, else sets pressure unit — see §3.17. |
| `0x39` | `hrvSetting` | `0x0082c9da` | Reads/sets HRV config; uses `FUN_0083468e` — see §3.21. |
| `0x3a` | `sugarLipidsSetting` | `0x0082cc1e` | Sub `0x03`/`0x04` read/write sugar/lipids settings — see §3.22. |
| `0x3b` | `uvSetting` / `touchControl` | `0x0082cbc8` | Read/write UV/touch config byte at `DAT_0082cfe8 + 8` — see §3.18. |
| `0x43` | `readDetailSport` | `0x0082d034` | Reads detailed sport records by date range — see §3.6. |
| `0x72` | `pushMsgUint` | `0x00829e92` | Buffers a notification/emoji Unicode string for display — see §3.3. |
| `0x77` | `phoneSport` | `0x0082ce0c` | Jump-table dispatch on sub-byte. |
| `0x7a` | `muslim` | `0x0082cb3a` | Sub `0x01` reads Muslim prayer config, `0x02 0x01` resets it — see §3.11. |
| `0x81` | — | `0x0082cdac` | Stores 6-byte config chunk and calls `FUN_00840568` (flash/config write). |
| `0xa1` | — | `0x00827f5c` | Factory/test mode commands (`0x01`–`0x06`): reset, read logs, power off, etc. |
| `0xc6` | `restoreKey` | special | Reboot sequence — see §3.14. |
| `0xc7` | — | `0x00832ebc` | Vibration/motor pattern player — see §3.2. |
| `0xff` | — | `0x0082cde8` | Factory reset — see §3.8. |

### Common response path

Most handlers build a 16-byte response buffer, compute an additive checksum with `FUN_0082b0c4`, and send it via `FUN_0082ebdc`:

| Address | Function | Role |
|---|---|---|
| `0x0082b0c4` | `FUN_0082b0c4` | Additive byte checksum (sum of first 15 bytes → byte 15) |
| `0x0082ebdc` | `FUN_0082ebdc` | Queue 16-byte response into Channel A notify ring |
| `0x0082b938` | `FUN_0082b938` | Send a long response fragmented into 14-byte chunks |
| `0x0082c988` | `FUN_0082c988` | Stream large data for opcodes `0x37`, `0x39`, `0x7a` |

`FUN_0082b986(opcode, isNotify)` sends a simple 1-byte opcode response (with `0x80` flag for notify-only opcodes).

### 3.16 Opcode `0x77` `phoneSport` sub-command dispatch (`FUN_0082ce0c`)

The 0x77 handler is a *two-stage* dispatcher: the main handler
`FUN_0082ce0c` reads `req[1]` and indexes a switch8 at
`0x82ce23` (7 active entries, max-index `6`), then jumps to
one of the per-sub-byte thunks. The thunks are tiny
"register-only" stubs whose locals have all been optimized
out by the compiler — the decompiler shows them as
`unaff_r4..r7` because the parent dispatcher passes the
request pointer in `r4`, the state byte in `r5`, the sport
context in `r6`, and zero in `r7`, and the thunks reuse
those registers directly.

#### Dispatcher entry (`FUN_0082ce0c`)

```asm
push {r4,r5,r6,r7,lr}
mov  r4, r0                   ; r4 = request frame
ldrb r0, [r0, #1]             ; r0 = sub-byte
ldr  r1, [0x82cff8]           ; r1 = state ptr
sub  sp, #0x14
ldr  r6, [0x82cff4]           ; r6 = sport context ptr
ldrb r5, [r1]                 ; r5 = state byte
movs r7, #0
movs r3, r0                   ; r3 = sub-byte (for switch8)
bl   0x8405fc                ; __ARM_common_switch8
```

So the registers passed into the per-sub-byte thunks are:
- `r4` = request frame pointer
- `r5` = 1-byte sport state (loaded from `*DAT_0082cff8`)
- `r6` = sport context (20-byte block at `DAT_0082cff4`)
- `r7` = 0

The switch8 at `0x82ce23` dispatches on `req[1]` to:

| `req[1]` | Thunk | Notes |
|---:|---|---|
| `0x00`, `0x06` | `FUN_0082cede` | Default ack — builds `0x77` response with checksum |
| `0x01` | `FUN_0082ce2a` | Start/finish sport session |
| `0x02` | `FUN_0082ce64` | Pause / resume bit |
| `0x03` | `FUN_0082ce72` | Lap / split bit |
| `0x04` | `FUN_0082ce80` | Cancel sport session |
| `0x05` | `FUN_0082ce96` | GPS/position delta |

#### Sub-handler details

The `unaff_r*` accesses are the optimizer-removed parameters.
The recovered semantics are:

* **`0x01` start/finish (`FUN_0082ce2a`)**:
  1. `memset(sport_ctx, 0, 0x14)` — clear the 20-byte sport context.
  2. If `r5 != 0` (state byte): call `FUN_00830c7e()` (stop sport).
  3. `FUN_00828af4()` — HR step-counter running check; if non-zero,
     call `FUN_0082b108()` (likely the same "ack" builder used by
     the deferred ring) and return — *sport session cannot start
     while HR is busy*.
  4. `FUN_00830c82(req[2])` — start sport in mode `req[2]`
     (the per-mode flag from the H59MA SDK).
  5. `*sport_ctx = 1` — set "running" flag at offset 0.
  6. `func_0x00013694(DAT_0082cffc, 1000)` — arm a 1000 ms
     one-shot timer at the 2nd literal-pool slot (the 1 Hz sport
     tick that the main loop drains to update step counts).
  7. `FUN_0082b108()` + `FUN_0082cede()` — emit the 0x77 ack.

* **`0x02` pause bit (`FUN_0082ce64`)** and **`0x03` lap bit
  (`FUN_0082ce72`)** are mirror images: if `r5 != 0`, set
  `*(sport_ctx + 1) = 1` (the "pause/lap in progress" flag),
  call `FUN_00830cb2` (pause) or `FUN_00830cbc` (lap), restore
  the original `r7` value (always 0 in the dispatcher) to byte
  1, and emit the ack. If `r5 == 0`, the call is a no-op
  `FUN_0082b0c4` + `FUN_0082ebdc` (i.e. an empty response).

* **`0x04` cancel (`FUN_0082ce80`)**: cancel the 1000 ms tick
  timer via `func_0x000136bc(DAT_0082cffc)`, set the in-progress
  flag at `sport_ctx[1] = 1` (so the dispatcher's "if r5 != 0"
  guard is satisfied for the remainder of the session), call
  `FUN_00830c7e()` to stop the step-counter / sport-motion
  library, and emit the ack.

* **`0x05` GPS delta (`FUN_0082ce96`)** is the only data-bearing
  sub-byte. The handler reads two 3-byte little-endian u24 values
  from the request and integrates them into cumulative counters
  on the sport context:

  ```c
  uint32_t new_lat = (req[3] | (req[4] << 8) | (req[5] << 16));
  uint32_t new_lng = (req[7] | (req[8] << 8) | (req[9] << 16));
  sport_ctx[0xc / 4] += (int32_t)(new_lat - sport_ctx[4 / 4]);  // lat delta
  sport_ctx[0x10 / 4] += (int32_t)(new_lng - sport_ctx[8 / 4]); // lng delta
  sport_ctx[4 / 4] = new_lat;
  sport_ctx[8 / 4] = new_lng;
  ```

  The 12-byte sport context fields are therefore:

  | Off | Field | Notes |
  |---:|---|---|
  | 0 | `running_flag` | 1 if a session is in progress |
  | 1 | `pause_or_lap_flag` | 1 if a pause/lap sub-cmd is mid-handler |
  | 2..3 | (unused) | |
  | 4..7 | `last_lat` (u32 LE) | last reported latitude value |
  | 8..11 | `last_lng` (u32 LE) | last reported longitude value |
  | 12..15 | `cum_lat` (i32 LE) | cumulative latitude delta |
  | 16..19 | `cum_lng` (i32 LE) | cumulative longitude delta |

  The two u24 values in the request are **arbitrary bit-pattern
  encodings** of latitude and longitude, not BCD degrees-minutes;
  the watch just keeps a running sum of the per-tick deltas and
  surfaces the total in the 0x77 response. The `req[1] == 0x01
  || req[1] == 0x06` branch in the sub-handler is the same
  guard that the default-ack thunk uses to decide whether to
  emit a 14-byte response or a 0-byte response.

The helper functions `FUN_00830c7e`, `FUN_00830cb2`, `FUN_00830cbc`,
`FUN_00830c82` live in the step-counter / sport-motion library
(`vc_SportMotion_Int`) referenced in
`firmwares/_re/strings-mining/findings.txt`.

### 3.17 Opcode `0x38` pressure (1-bit read/write) (`FUN_0082ca54`)

The simplest "1-bit setting" pair in the table — analogous to
the `0x2c bloodOxygenSetting` handler from §3.10. The
"pressure value" is a single bit stored in the same shared
config byte at `DAT_008277f0 + 0x2D` that holds the SpO2 flag,
UV-touch byte, etc.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper used |
|---:|---|---|
| `0x01` (read) | `cStack_1e = FUN_00827772()` — read bit 3 of `*(DAT_008277f0 + 0x2D)`, masked `& 0xF >> 3` yields `0` or `1` | `FUN_00827772` |
| other (write) | `FUN_0082777e(req[2] == 1)` — if `req[2] == 1`, set bit 3; else clear it. The handler then **echoes** `req[2]` (not the coerced 0/1) into the response. | `FUN_0082777e` |

The mask `& 0xF` and the `<< 3` shift confirm that only bit 3
of the shared config byte is owned by the pressure setting;
the other 7 bits of that byte belong to other features
(SpO2, UV-touch, etc.).

#### Response layout (3 useful bytes + 13 zero bytes + checksum)

```
byte  0: 0x38                (cmd echo)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: pressure value      (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

The response is built directly on the stack (the handler
clears the 16-byte frame once at the top and writes only the
three output bytes), so the rest of the frame is always zero.

#### Why this is so short

* The 1-bit storage means the entire pressure "value" is a
  boolean — the H59MA pressure sensor (if present) is either
  enabled or disabled, not a continuous reading. A host that
  wants the actual mmHg / kPa reading must subscribe to a
  push channel (likely a `0x2B`-routed event) rather than
  poll `0x38`.
* The 0/1 read and the echoed `req[2]` write response are
  **deliberately consistent** with the `0x2c` SpO2 and `0x3b`
  UV-touch handlers — the host code can treat all three
  "1-bit setting" opcodes uniformly with the same
  `read = 0x01 / write = 0x02` sub-opcode pattern.

#### Companion opcode `0x37` pressureSetting

`0x37` (`FUN_0082caa6`) is a *separate* config opcode that
uses the same shared `FUN_0082c988` 13-byte-chunk fragmenter
as `0x7a muslim` (§3.11) and `0x39 hrv`. It likely configures
the per-mode pressure algorithm (high/low threshold, alert
frequency, etc.) rather than the on/off bit that `0x38`
owns. The host should not confuse the two: `0x37` is the
*settings* opcode (long fragmented response), `0x38` is the
*value* opcode (3-byte ack).

### 3.18 Opcode `0x3b` uvSetting / touchControl (`FUN_0082cbc8`)

A 1-byte read/write of the UV / touch-screen control byte
stored at `DAT_0082cfe8 + 8` (a different config struct from
the one used by `0x2c` SpO2 and `0x38` pressure — this one
lives in the *display* config block rather than the
*sensor* config block). The handler is also notable for its
**"echo the request" response** pattern: instead of building
the response from scratch, it `memcpy`s the 16-byte request
into the response buffer and overwrites only byte 0 (with
the cmd) and byte 15 (with the checksum).

#### Sub-opcode dispatch

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x01` | `0x00` | **Read**: `uStack_15 = *(DAT_0082cfe8 + 8)` (returns the 1-byte UV/touch config) |
| `0x02` | `0x00` | **Write**: `*(DAT_0082cfe8 + 8) = req[3]`; commit via `FUN_00827624()` |
| other | `0x00` | No-op: response is just an echo of the request |
| any | `!= 0x00` | No-op: response is just an echo of the request |

The `req[2] == 0` guard is unusual — most config opcodes
treat `req[1]` as the only sub-opcode. Here, `req[2]` is a
**"batch mode"** flag: when set, the read/write is *not*
performed and the watch just echoes the request back. This
is the same pattern that `0x18 displayClock` uses for its
"label ≥ 13 bytes" spill to `DAT_0082cfec` (see §3.5) — a
host that wants to push a multi-frame value sends the first
frame with `req[2] != 0` (so the watch doesn't commit
prematurely) and the last frame with `req[2] == 0` (so the
watch commits the final value).

#### Response layout (16-byte frame, mostly request-echo)

```
byte  0: 0x3B                 (cmd, overwritten)
byte  1: req[1]               (sub-opcode echo)
byte  2: req[2]               (echo — batch-mode flag preserved)
byte  3: read value (0x01 path) | req[3] (0x02 path) | req[3] (no-op)
byte  4..14: req[4..14]       (echo)
byte 15: additive checksum    (per §3)
```

Because the handler `memcpy`s the request into the response
*before* touching bytes 0/3, the only fields that ever differ
between the request and the response are byte 0 (always
`0x3B`) and byte 3 (only for the `0x01` read path). The
rest of the response is a byte-for-byte echo.

#### Persistent state

| Off | Field | Notes |
|---:|---|---|
| `DAT_0082cfe8 + 8` | `uv_touch_config` (u8) | the 1-byte control value |

Unlike `0x2c` (`*(DAT_008277f0 + 0x2D)` bit 1) and `0x38`
(`*(DAT_008277f0 + 0x2D)` bit 3), the UV/touch value is a
**full byte** (0..255), not a 1-bit flag. The host should
not assume any particular bit layout when reading it back;
treat the value as an opaque feature-mode byte that the
firmware-side producer (the UV sensor / touch-screen
driver) consumes.

#### `FUN_00827624` — config-commit

Called on the write path after the byte is stored. Same
function used by `0x01 setTime` and by the Channel-A
dispatcher's restart paths (§3.4). Marks the config
*dirty* so the next `0x81` config-chunk write flushes the
new value to flash, and re-arms the bitmap-driven
UI re-render.

#### Why the request-echo response

* For a *single-frame* read or write, the echo is
  indistinguishable from a hand-built response and saves a
  handful of cycles per handler invocation.
* For the *multi-frame batch* use case, the echo doubles as
  a frame-receipt: the host can use the unmodified bytes
  4..14 in the response as confirmation that the same
  payload arrived intact, without a separate echo frame.

### 3.19 Opcode `0x0e` bpReadConform (BP record index advance) (`FUN_0082cb28`)

The smallest handler in the Channel-A table (17 bytes): a
"confirm and advance" command for the blood-pressure record
queue. The request opcode is `0x0E` but the response
opcode is `0x0D` (BP *record* read) — the request is the
"please advance and emit next record", the response is the
record itself.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x0E` | cmd (consumed by dispatcher) |
| 1 | `sub` | `0` → advance + read next; other → no-op |
| 2..14 | unused | — |

The handler does not respond to a non-zero `sub`; it silently
exits. The "advance" semantics is *not* implicit in receiving
the opcode — the host must explicitly request the advance by
sending `sub == 0`, which gives the host a clean way to poll
without consuming records.

#### Behavior (sub == 0)

```c
void FUN_0082cb28(int param_1) {
    if (param_1[1] != 0) return;
    FUN_00834410();   // advance the BP record index
    FUN_0082c0a4();   // read next record + emit fragmented 0x0D response
}
```

`FUN_00834410` advances a circular index:

```c
void FUN_00834410() {
    state = DAT_008344ac;
    *(u32*)(state + 0x10 + *(u8*)(state + 0xE) * 4) = 0;  // clear current slot
    *(u8*)(state + 0xE) = *(u8*)(state + 0xE) + 1;          // index++
}
```

So `DAT_008344ac` is the BP-record-queue state, byte `+0xE`
is the "current read index" (wraps at 256), and bytes
`+0x10 + idx*4` are a circular buffer of u32 slots — each
slot is presumably the "this record was read at time T" or
"this record's read-confirm flag" (the handler zeros the slot
on advance, presumably so a subsequent re-read of the same
slot will get a fresh value).

`FUN_0082c0a4` then reads the next BP record and ships it:

```c
void FUN_0082c0a4() {
    int n = FUN_00834296(&hdr, &body);        // fill header (14 B) + body
    if (n != 0xff) {
        FUN_0082b938(0x0D, &hdr, 0xE);        // fragment #1: 14 B header
        if (n != 0) {
            FUN_0082b938(0x0D, &body, n);     // fragment #2: n B body
        }
    }
}
```

* The response cmd is **`0x0D`**, not `0x0E` — the dispatcher
  emits a *different* opcode for the response than the request.
  This is the only such case in the Channel-A table; all
  other "config read" opcodes echo the request cmd.
* `FUN_0082b938` is the shared 14-byte-chunk fragmented
  streamer (see §3.2) used by 0x18 / 0xC7 and others. A
  BP record is split into a fixed 14 B header + variable B
  body, so a record larger than 14 B takes 2 notify frames.
* `FUN_00834296` returns `0xFF` to mean "no record" — the
  handler then sends nothing (the "no data" path).

#### Response layout

For a 14-byte BP record: a single 16-byte notify frame
`[0x0D, 14 B record data, 0, 0, additive checksum]`.

For a longer BP record: two 16-byte notify frames:
```
frame 1: [0x0D, 14 B header..., additive checksum]
frame 2: [0x0D, N B body...,      additive checksum]
```

The two-frame boundary is the same 14-byte split used by
`0x18 displayClock`'s `FUN_0082b938` (the doc's "Common
response path" helper), so the host can reuse the same
14-byte collection logic it already uses for `0x18`.

#### Why the request/response opcode split

* The watch's BP *measurement* is triggered separately (e.g.
  the `0xA1 0x04` factory test path or a real measurement
  request), and produces a record that ends up in the
  internal queue. The host then polls `0x0E` to *confirm* it
  has read the next record, which both advances the index
  and triggers the next read.
* Splitting "advance" from "read" lets a host that needs to
  throttle polls (e.g. on a slow link) send `0x0E 0x01`
  repeatedly without ever consuming a record, and then send
  `0x0E 0x00` exactly once when ready to read.

#### Why no ack for the request

The 0x0E handler never emits a 0x0E response — the response
*is* the 0x0D frame (or its absence when the queue is
empty). A host that sends `0x0E 0x00` and receives nothing
within the BLE link timeout should treat the queue as
exhausted.

### 3.20 Opcode `0x37` pressureSetting (`FUN_0082caa6`)

Structurally a *clone* of the `0x7a muslim` handler (§3.11) —
same two-phase response (header frame + 4-frame fragmented
49-byte payload), same 13-byte-chunk fragmenter
`FUN_0082c988`. The two differences are:

* The producer `FUN_008344fe` is a **real implementation** (not
  a stub like `FUN_00829c88`).
* The header literal dword is `0x1E050037` (LE), not
  `0x3C05007A`; byte 3 is `0x1E` (30) rather than `0x3C` (60).
  The host can use this byte to disambiguate the two
  long-response opcodes if the cmd byte is lost in a
  fragmentation boundary.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x37` | cmd (consumed by dispatcher) |
| 1 | `slot_id` | day offset (current day = `slot_id == 0`) |
| 2..14 | unused | — |

Only `slot_id == 0` (today) is supported by the "happy path"
in v14 — the dispatcher in §3 routes every non-zero sub-cmd
to the default-slot (`FUN_0082cede` in 0x7a's case, the same
here). Sub-`0x01` etc. are not implemented; the only valid
host request is `0x37 0x00` (read today's pressure setting).

#### Behavior

```c
void FUN_0082caa6(int param_1) {
    memset(stack, 0, 0x10);          // clear 16 B response
    memset(stack, 0, 0x34);          // clear 52 B pressure data buffer
    if (FUN_008344fe(param_1[1], &buf) == 0) {
        // No record for this slot: send error
        rsp[0..1] = 0x37 | 0xFF;     // little-endian: byte 0 = 0x37, byte 1 = 0xFF
        FUN_0082ebdc(rsp);           // queue the error frame
    } else {
        // Record found: send header + 4-frame fragmented payload
        rsp[0..3] = 0x1E050037;      // little-endian: 0x37, 0x00, 0x05, 0x1E
        FUN_0082ebdc(rsp);
        buf[0] = param_1[1];         // slot id echo
        FUN_0082c988(0x37, buf, 0x31);   // fragment 49 B into 4 frames
    }
}
```

#### `FUN_008344fe` — pressure record read

```c
uint FUN_008344fe(int slot_id, u32 *out) {
    int month = FUN_0082840e();           // current month
    pressure_rec *r = FUN_0082966e(       // look up by month offset
        DAT_00834648, *DAT_00834644, month - slot_id
    );
    if (r == NULL) return 0;              // no record: 0 means "empty"
    *out = *r;                            // copy 4-byte header
    for (int i = 0; i < 0x30; i++) {     // copy 48 B body
        if (r->body[i] == -1 || r->body[i] == 0)
            out->body[i] = 0;            // null-terminate
        else
            out->body[i] = r->body[i];
    }
    return 0x30;                          // body length
}
```

So the pressure record is 4 bytes of header + 48 bytes of
string-like body, stored in a record table indexed by
`month_offset` from today. The body is *null-terminated in
the response* even when the source record is `-1`-padded
(presumably to keep the body length consistent across
uninitialised records).

#### Response layout (mirrors 0x7a)

Phase 1 — header:
```
byte  0: 0x37
byte  1: 0x00
byte  2: 0x05         (5-dword payload size? see §3.11)
byte  3: 0x1E         (the "feature id" — 30 instead of muslim's 60)
byte  4..14: 0
byte 15: additive checksum
```

Phase 2 — 4 frames via `FUN_0082c988(0x37, &buf, 0x31)`:
```
frame N (N=1..4):
  byte  0: 0x37
  byte  1: N
  byte  2..14: 13 bytes of (1-byte slot id + 48-byte body)
  byte 15: additive checksum
```

The slot id is at payload byte 0 (echo of `req[1]`), and the
48-byte body starts at payload byte 1.

#### Comparison with `0x7a muslim`

| | `0x37` pressureSetting | `0x7a` muslim |
|---|---|---|
| Producer | `FUN_008344fe` (real) | `FUN_00829c88` (stub) |
| Header dword | `0x1E050037` | `0x3C05007A` |
| Body shape | 4 B header + 48 B body | (same) |
| Fragment count | 4 | 4 |
| Slot-id echo at payload byte 0 | yes | yes |

Both opcodes are routed through `FUN_0082be64` (the deferred
ring) by the Channel-A dispatcher, so a host that issues
`0x37` and `0x7a` in quick succession will see both
fragments come back interleaved on the notify ring — the
host should re-sync on each `byte 0 == 0x37` or `0x7A`
header to separate the two streams.

#### Why 30 (0x1E) and not 60 (0x3C) for the feature id

The `0x3C` in `0x7a muslim`'s header and the `0x1E` in
`0x37 pressureSetting`'s header are likely **indexes into
the same per-feature config table**. The dispatcher (and
the long-config shared fragmenter from §3.11) does not
*interpret* these bytes — they are producer-specific
identifiers that the host-side SDK uses to know which
feature a given header belongs to. The two-byte pattern
`{opcode_byte, 0x00, 0x05, feature_id}` is the "long
config" ack shape that all the §3.11 / §3.20 handlers
use.

### 3.21 Opcode `0x39` hrvSetting (`FUN_0082c9da`)

The third and final member of the *shared-fragmenter
trio* (after `0x37 pressureSetting` §3.20 and `0x7a muslim`
§3.11). Structurally a near-clone of `0x37` — same
two-phase response, same 4-byte header + 48-byte body
shape, same 4-frame fragmented 49-byte payload via
`FUN_0082c988` — with a different producer and header
literal.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x39` | cmd (consumed by dispatcher) |
| 1 | `slot_id` | day offset (current day = `slot_id == 0`) |
| 2..14 | unused | — |

Identical to `0x37 pressureSetting`. Only `slot_id == 0`
(today) is on the happy path; the dispatcher routes every
other sub-cmd to the default-slot ack.

#### Behavior

```c
void FUN_0082c9da(int param_1) {
    memset(stack, 0, 0x10);
    memset(stack, 0, 0x34);
    if (FUN_0083468e(param_1[1], &buf) == 0) {
        rsp[0..1] = 0x39 | 0xFF;            // little-endian: byte 0 = 0x39, byte 1 = 0xFF
        FUN_0082ebdc(rsp);                  // queue "no record" error
    } else {
        rsp[0..3] = 0x1E050039;             // little-endian: 0x39, 0x00, 0x05, 0x1E
        FUN_0082ebdc(rsp);
        buf[0] = param_1[1];                // slot id echo
        FUN_0082c988(0x39, buf, 0x31);      // fragment 49 B into 4 frames
    }
}
```

Compare to §3.20's `0x37 pressureSetting`: the only byte that
differs is the **cmd** in the header dword (`0x37` vs `0x39`);
byte 3 (the feature id `0x1E`) is the *same* for both,
suggesting that the watch's per-feature config table groups
pressure and HRV together under feature id `0x1E` (30).

#### `FUN_0083468e` — HRV record read

```c
uint FUN_0083468e(int slot_id, u32 *out) {
    int month = FUN_0082840e();
    hrv_rec *r = FUN_0082966e(        // look up by month offset
        DAT_008347dc, *DAT_008347d8, month - slot_id
    );
    if (r == NULL) return 0;            // no record
    *out = *r;                          // copy 4-byte header
    for (int i = 0; i < 0x30; i++) {   // copy 48 B body
        if (r->body[i] == -1 || r->body[i] == 0)
            out->body[i] = 0;          // null-terminate
        else
            out->body[i] = r->body[i];
    }
    return 0x30;
}
```

This is the **same body shape** as `FUN_008344fe` (§3.20) but
with a different data-table pointer (`DAT_008347dc` /
`*DAT_008347d8` instead of `DAT_00834648` / `*DAT_00834644`).
Both producers look up records in a shared "per-day record
table" indexed by month-offset from today, so the host can
treat them uniformly: ask for "today" and get a 4-byte
header + 48-byte body, or ask for a different day and get
the same shape (or an error frame for an empty slot).

#### Response layout (mirrors 0x37)

Phase 1 — header:
```
byte  0: 0x39
byte  1: 0x00
byte  2: 0x05
byte  3: 0x1E         (same feature id as 0x37!)
byte  4..14: 0
byte 15: additive checksum
```

Phase 2 — 4 frames via `FUN_0082c988(0x39, &buf, 0x31)`:
```
frame N (N=1..4):
  byte  0: 0x39
  byte  1: N
  byte  2..14: 13 bytes of (1-byte slot id + 48-byte body)
  byte 15: additive checksum
```

The slot id is at payload byte 0, and the 48-byte body starts
at payload byte 1.

#### Trio summary

| | `0x37` pressureSetting | `0x39` hrvSetting | `0x7a` muslim |
|---|---|---|---|
| Header dword | `0x1E050037` | `0x1E050039` | `0x3C05007A` |
| Feature id (byte 3) | `0x1E` (30) | `0x1E` (30) | `0x3C` (60) |
| Producer | `FUN_008344fe` (real) | `FUN_0083468e` (real) | `FUN_00829c88` (stub) |
| Body shape | 4 B header + 48 B body | same | same |
| Fragmenter | `FUN_0082c988` | same | same |

The fact that `0x37` and `0x39` share the same feature id
(`0x1E`) while `0x7a` uses a different one (`0x3C`) implies
the firmware has at least **two distinct long-config feature
groups**: "sensor metrics" (pressure + HRV, both under
`0x1E`) and "user-content" (muslim, under `0x3C`). The host
SDK can use the feature id to decide which body-shape parser
to apply when it receives a fragmented long-config response.

### 3.22 Opcode `0x3a` sugarLipidsSetting (`FUN_0082cc1e`)

A **two-bit-per-feature config pair** — sugar and lipids
monitoring are 1-bit on/off flags packed into the same shared
config byte at `DAT_008277f0 + 0x2D` already used by
`0x2c` SpO2 (§3.10) and `0x38` pressure (§3.17).

#### Persistent state (1 bit each)

| Field | Bit position in `*(DAT_008277f0 + 0x2D)` | Read helper | Write helper |
|---|---:|---|---|
| sugar setting | bit 5 | `FUN_00827790` (`(*(byte*) & 0x3F) >> 5`) | `FUN_0082779c` (`... & 0xDF | (v << 5)`) |
| lipids setting | bit 7 | `FUN_008277ce` (`*(byte*) >> 7`) | `FUN_008277d8` (`... & 0x7F | (v << 7)`) |

The masks (`0x3F`, `0xDF`, `0x7F`) and shifts (`>> 5`, `<< 5`,
`>> 7`, `<< 7`) prove these are the only bits the handlers
own; the other 6 bits of `*(DAT_008277f0 + 0x2D)` belong to
the other 1-bit features. Combined with §3.10 / §3.17 the
full bit map is:

| Bit | Owner |
|---:|---|
| 1 | SpO2 (`0x2c`) |
| 3 | Pressure (`0x38`) |
| 5 | Sugar (`0x3a` sub 0x03) |
| 7 | Lipids (`0x3a` sub 0x04) |

#### Sub-opcode dispatch

`req[1]` selects the feature; `req[2]` selects read vs write.

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x03` | `0x01` | **Read sugar**: response `[0x3A, 0x03, 0x01, sugar_value, 0, …, 0, cksum]` |
| `0x03` | `0x02` | **Write sugar**: `FUN_0082779c(req[3] != 0)`; response = the **request frame echoed unchanged**; on first commit, also set `*(DAT_0082cfe8 - 0x92) = 0x1E` (mark "config block initialised") |
| `0x03` | other | no-op, no response |
| `0x04` | `0x01` | **Read lipids**: response `[0x3A, 0x04, 0x01, lipids_value, 0, …, 0, cksum]` |
| `0x04` | `0x02` | **Write lipids**: `FUN_008277d8(req[3] != 0)`; response = `[0x3A, 0, 0, 0, 0, …, 0, cksum]` (1-byte-cmd ack — *not* an echo) |
| `0x04` | other | no-op, no response |
| other | any | no-op, no response |

#### Asymmetric write responses

The handler uses two *different* response shapes for the two
write paths:

* **Sugar (`0x03 0x02`)**: the request frame is **echoed
  unchanged** via `FUN_0082ebdc(param_1)` — same pattern as
  `0x06 DND` (§3.7) and `0x3b uvTouch` (§3.18). The host
  treats the echo as a self-describing ack and can verify
  the exact `(feature, sub, value)` triple the watch
  committed.
* **Lipids (`0x04 0x02`)**: the response is a minimal
  `[0x3A, 0, …, 0, cksum]` — only the cmd byte is set. This
  is the same shape as `0x1e realTimeHeartRate`'s 1-byte
  ack (§3.13). The host must use a follow-up `0x04 0x01`
  read to confirm the value actually changed.

This asymmetry is the only place in the Channel-A table
where two structurally identical "1-bit config write" pairs
use different ack shapes. The host code that consumes
these handlers should not assume a uniform "echo-on-write"
behaviour across all 1-bit config opcodes.

#### First-time-init side effect

The sugar write path also has a one-shot side effect: if
`*(DAT_0082cfe8 - 0x92) == 0`, set it to `0x1E`. This flag
is the "config block initialised" sentinel — it likely
tells the next `0x81` config-chunk flush (§3.5) that the
sugar / lipids config is part of the persistent block that
must be written to flash. The lipids write path does *not*
have this side effect, which suggests the firmware
considers the sugar bit a "primary" config and the lipids
bit a "secondary" one (or vice-versa, depending on the
producer's view of which one is the canonical setting).

#### Response layout (read paths)

```
byte  0: 0x3A
byte  1: req[1]              (0x03 sugar / 0x04 lipids)
byte  2: 0x01                (read sub-cmd echo)
byte  3: feature value       (0 or 1)
byte  4..14: 0
byte 15: additive checksum
```

The response is built on the stack from the saved-register
slots used by the dispatcher (no `memcpy` from the request),
so the only non-zero output bytes are 0..3 + 15.

### 3.2 Opcode `0xc7` vibration / motor pattern player (`FUN_00832ebc`)

A two-mode motor controller dispatched by the value of `*DAT_00833188`
(default `'D'` = `0x44`; alternative `'#'` = `0x23`). The handler
re-uses the same 12-byte payload that follows the first three bytes of
the 16-byte request, passed through the caller's saved register slots
(`push {r2,r3,r4,lr}`).

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `presence` | `0` → stop; non-zero → play |
| 1 | `pattern_id` | low 7 bits; ORed with `0x80` to mark "play" on the play path |
| 2 | `duration` | clamped to 6 |
| 3..14 | `pattern` | 12 bytes of pattern data (motor strength, rhythm, etc.) |
| 15 | checksum | additive (per §3) |

#### Behavior

* If `presence == 0` (stop path):
  * mode `'#'` → `FUN_00831fde(pattern_id, duration)` — stop pulse-pattern
  * mode `'D'` → `FUN_00832044(pattern_id, duration)` — stop duration-pattern
  * No response frame is sent.
* If `presence != 0` (play path, `length = min(duration, 6)`):
  * mode `'#'` → `FUN_00831faa(pattern_id | 0x80, &pattern, length)` — play pulse-pattern
  * mode `'D'` → `FUN_00832010(pattern_id | 0x80, &pattern, length)` — play duration-pattern
  * In both cases, the response is a **fragmented** `0xC7` frame sent
    via `FUN_0082b938(0xC7, &pattern, length)`. The fragmentation
    helper packs at most 14 payload bytes per 16-byte notify frame
    with additive checksum.

#### `FUN_0082b938` (fragmented response)

```c
void FUN_0082b938(byte cmd, int payload, uint length) {
  do {
    chunk = min(length, 0xe);     // 14 payload bytes per frame
    frame[0] = cmd;
    memcpy(&frame[1], payload, chunk);
    frame[15] = FUN_0082b0c4(frame, 0xf);   // additive checksum
    FUN_0082ebdc(frame);
    payload += chunk;
    length  -= chunk;
  } while (length != 0);
}
```

The fragmenter is shared with `0x18 displayClock`, `0xc1 0xFEE7 long`
and any handler that needs to send a >14-byte response (e.g. the
`0x40..0x42` file-list responses and the `0x27/0x3e` sleep records).

#### `FUN_00831faa` (mode `#` play, returns success bool)

```c
uint FUN_00831faa(id, payload, length) {
  if (func_0x000133f4(*DAT_0083230c, 100) == 0) return 0;  // mutex acquire
  ok = (FUN_008336e8(0x1f, id, payload, length) == 0);     // 0x1F = "play pattern" motor cmd
  func_0x0001341c(*DAT_0083230c);                          // mutex release
  return ok;
}
```

The `0x1F` value pushed to `FUN_008336e8` is the motor-driver
sub-command for "play pattern"; `0x20` is its "stop" counterpart used
by the no-presence path. The `*DAT_0083230c` mutex pointer is the same
serialising lock used by all motor-handler routines (`FUN_00831fde`,
`FUN_00832010`, `FUN_00832044`), so two patterns cannot be active at
once.

### 3.3 Opcode `0x72` push-message / Unicode notifier (`FUN_00829e92`)

The watch-side handler for an incoming push notification or
emoji-bearing string. The handler is a **chunked accumulator** — the
host may issue several `0x72` frames in a row, each appending 11 bytes
to an internal buffer, then send a final "flush" frame to render.

The handler maintains a private context anchored at `DAT_00829f6c`:

| Offset (from `DAT_00829f6c`) | Field | Notes |
|---:|---|---|
| `-0xa7` | `cursor` (u8) | Current write position in the text buffer |
| `-0x88` | `text[0x85]` | 133-byte UTF-8 message buffer |
| `+0x08` | `category` (u8) | Set by the renderer to `0` (idle) or `0x16` (displayed) |

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x72` (consumed by dispatcher) |
| 1 | `notification_type` | 0..14, indexes a per-type table at `DAT_00829f7c - 0x18` |
| 2 | `flush_marker` | When `== flush_marker` of the *next* byte, the buffer is rendered and cleared |
| 3 | `flush_marker` (echo) | Must match byte 2 to trigger a flush — avoids spurious flushes from stale data |
| 4..14 | `payload[11]` | Up to 11 UTF-8 bytes appended to the message buffer |

The `flush_marker` equal-pair guard is the *only* thing distinguishing
"data" frames from "end-of-message" frames, so the host can stream
arbitrarily long messages with no length prefix.

#### Accumulator (`FUN_00829e92`)

1. If `cursor + 11 ≤ 0x84` (still room in the 133-byte buffer):
   - `memcpy(text + cursor, payload, 11)`
   - `cursor += 11`
2. If `req[2] == req[3]` (flush trigger):
   - `FUN_0082b986(0x72, 0)` — send a 1-byte `0x72` ack.
   - If `notification_type < 15`:
     - If `cursor > 0x74` (text would exceed 116 bytes), walk the
       buffer from byte 0 parsing UTF-8 lead-byte widths
       (1, 2, 3, 4, 5, 6, 7 for ranges `<0x80`, `0xC0..0xDF`,
       `0xE0..0xEF`, `0xF0..0xF7`, `0xF8..0xFB`, `0xFC..0xFD`,
       else) and stop at the last codepoint that fits before
       offset `0x7D` (125). Append the UTF-8 ellipsis
       (`\xE2\x80\xA6`) at the truncation point and bump the
       cursor past it.
     - Look up `table[notification_type]` in the 16-byte type table
       at `DAT_00829f7c - 0x18` to get the *category* byte, then
       call `FUN_00829cfe(&state)` to render.
   - `memset(text, 0, 0x85)` and reset `cursor = 0` regardless of
     whether a render happened.

#### Renderer (`FUN_00829cfe`)

The renderer's `state` dword is `[type, ?, category]`. It dispatches
on the `category` byte:

| Category | Behavior |
|---:|---|
| `0x00` | If the user is on the home screen (`FUN_0082a826() == 0`) **and** the per-type enabled bit at `*(iVar6 + 0x2c) & 1` is set, fire a short motor alert `FUN_0082994c(0x12, 1, 3, 0x32)`, store `type` at `*puVar2`, store the current RTC at `*(puVar2 + 4)`, and call `FUN_008279e4()` to draw the message buffer to the display. |
| `0x15` | `type == 0` clears any pending message: `FUN_00829a56()` + `FUN_0082a5cc()`. Other `type` values are no-ops (return). |
| other | If `type == 0` fire a long alert `FUN_0082994c(0x12, 1, 3, 5, ...)` + `FUN_0082a5b2(3)`. If `type == 1`, walk the 32-entry `category` table at `DAT_00829f7c` and fire the alert for any matching entry whose `*((iVar6 + 0x2c) & (1 << idx))` bit is set. Always set `puVar2[8] = 0x16` (mark "displayed"). |

`FUN_0082b986(cmd, isNotify)` (the small 1-byte opcode ack sender used
on the flush path) builds a 16-byte frame with `cmd` (or `cmd | 0x80`
for notify) at byte 0 and queues it via `FUN_0082ebdc` — see §3
"Common response path".

The handler is the watch's bridge between the
`ChannelADispatcher.pushMsgUint` stream (in `lib/core/protocol/channel_a.dart`)
and the on-screen notification UI; a peer on the host can use the
fragmented helper from §3.2 to send messages longer than 11 bytes per
frame.

### 3.4 Opcode `0x01` setTime / clock sync (`FUN_0082bb4e`)

The clock-sync handler. Decodes six BCD date/time bytes from the
request, applies the result to the RTC, and then sends a 14-byte
`0x01` capability-shaped ack that tells the host the new packet-size
capability the watch will use going forward.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x01` (consumed by dispatcher) |
| 1 | `year_lo` (BCD) | low byte of year, e.g. `0x26` for 2026 |
| 2 | `month` (BCD) | `0x01`..`0x12` |
| 3 | `day` (BCD) | `0x01`..`0x31` |
| 4 | `hour` (BCD) | `0x00`..`0x23` |
| 5 | `minute` (BCD) | `0x00`..`0x59` |
| 6 | `second` (BCD) | `0x00`..`0x59` |
| 7 | `flags` | `0xFF` → skip the "tick" re-init at the end of the handler; other → call `FUN_00827956()` + `FUN_008276d2()` (refreshes the live counter / re-arms the seconds tick) |
| 8..14 | unused | — |

`FUN_0082edc4(bcd)` is the BCD-to-binary helper used to decode every
field: returns `(hi_nibble*10 + lo_nibble) & 0xFF` if both nibbles
are `< 10`, else `0` (defensive default for malformed frames).

#### Pre-ack `0x2f` MTU notify

Before the `0x01` ack, the handler publishes the negotiated ATT MTU on
a separate opcode:

```c
uint8 mtu = FUN_0082df12();          // reads *(DAT_0082e054 + 0x19)
if (mtu < 0x33) mtu = 0x14;          // floor: ATT_MTU=23 ⇒ payload 20
FUN_0082b23a(0x2f, mtu);             // send 16-byte frame [0x2f, mtu, 0…]
```

`FUN_0082b23a` is the small "two-byte opcode sender" used elsewhere for
configuration pings: it builds a 16-byte frame, places the cmd in byte
0 and the parameter in byte 1, and queues it via `FUN_0082ebdc`. The
host reads the value as the new `payload_cap` for all subsequent
Channel-A frames.

#### RTC update logic

After BCD-decoding the 6 time fields into a stack struct
`{year, month, day, hour, minute, second}` and calling
`FUN_00827ba6(2)` (display refresh), the handler compares the parsed
time to the current RTC value (`FUN_00827956()`):

1. **First set** (`*(DAT_0082bfb8 + 2) == 0`):
   - `FUN_00828390(&parsed)` — convert BCD date struct to seconds
     since epoch (uses `FUN_00828176` to derive a day-of-year, then
     `day_of_year * DAT_008284f8 + hour*3600 + minute*60 + second`).
   - `FUN_00827948(seconds)` — set RTC.
   - Mark `*(DAT_0082bfb8 + 2) = 1` and `*(DAT_0082bfbc + 0xd) = 1`
     (the "time has been set" latches).
   - `FUN_00827624()` + `thunk_FUN_00827424()` — re-init the
     tick-driver and broadcast a fresh time to all consumers.
2. **Subsequent set**:
   - Compute `cur_q = FUN_0083dfba(cur_seconds, 900)` and
     `req_q = FUN_0083dfba(req_seconds, 900)` — the 15-minute
     quarter-hour buckets of the two times.
   - Same bucket: `FUN_00827948(req_seconds)` (set directly).
   - `cur < req` (the watch is behind): `FUN_00827948((cur_q + 1) * 900)`
     (set to the *next* quarter boundary, then `FUN_008317d4()` to
     align the tick display).
   - `0 < cur - req < 3` seconds: no-op (avoid jitter from a slow
     host).
   - Otherwise (forward jump): `FUN_00827948(req_seconds)` +
     `FUN_00827624()`.

The "set to the next 15-min boundary when behind" path is the
practical difference between this and a naïve "just write the time":
it prevents the watch from showing `:14:59` after a host that has
been disconnected for an hour pushes its clock.

#### Response layout (14 bytes via `FUN_0082b938`)

After the RTC is settled, the handler always sends a 14-byte `0x01`
ack with a fixed pattern:

```
local_30 = 0x16010000   // bytes  1..4:  0x00 0x00 0x01 0x16
local_2c = 0            // bytes  5..8:  0x00 0x00 0x00 0x00
local_28 = 0x200001     // bytes  9..12: 0x01 0x00 0x20 0x00
local_24 = 0x3000       // bytes 13..14: 0x00 0x00  (high 2 bytes 0)
```

After `FUN_0082b938(0x01, &local_30, 0xe)` the wire frame is

```
byte  0: 0x01                    // cmd
byte  1: 0x00
byte  2: 0x00
byte  3: 0x01
byte  4: 0x16
byte  5: 0x00
byte  6: 0x00
byte  7: 0x00
byte  8: 0x00
byte  9: 0x01
byte 10: 0x00
byte 11: 0x20
byte 12: 0x00
byte 13: 0x00
byte 14: 0x00
byte 15: additive checksum
```

The four little-endian dwords are a static capability shape used as
"set OK" — the host should treat the 14-byte payload as opaque and
parse the meaning only after the matching `0x5A 0x01` read of the
device-info block (see §2.7).

### 3.5 Opcode `0x18` displayClock / watch-face switcher (`FUN_0082ccb6`)

Sets the active watch face and accepts both numeric ("go to face N")
and string-labelled ("set face label to S") payloads. The handler
echoes the request back in a 16-byte response and updates the
display-render state via `FUN_0082e42c`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x18` (consumed by dispatcher) |
| 1 | `style` | sub-type selector — see below |
| 2 | `length` | only meaningful for label styles; `0x00..0x0C` echo-in-response, `0x0D..0xFF` spill to `DAT_0082cfec` |
| 3..14 | `payload` | label bytes (style 0x02/0x12/0x22/0x32) or ignored (other) |
| 15 | checksum | additive (per §3) |

#### `style` dispatch

| `style` | Action |
|---:|---|
| `0x01` | Numeric face index — calculates the new face's "label length" using `strlen()` on a previously-cached face-name buffer (`acStack_39`), then echoes that length in `response[2]` and copies the matching tail into `response[3..]`. Two sub-cases: a previous face whose name starts with `"O_"` (3-char prefix, label = `strlen - 7`), or any other name (label = `strlen - 4`, with one extra character trimmed if the slice ends in `'_'`). |
| `0x02`, `0x12`, `0x22`, `0x32` | Label style — the high nibble of `style` (`>> 4` = 0..3) is the *face-slot* index. The handler stores the label either inline (length < 13) or in a side buffer at `DAT_0082cfec` (length ≥ 13), then calls `FUN_0082e42c(payload, length, 0xa5 - slot)` to push it to the display renderer. |
| other | Pass-through — `response[2]` is left at `0x00`, the rest of the response is zero. |

#### Side-buffer spill (`style` 0x02/0x12/0x22/0x32, `length ≥ 13`)

The handler re-uses a 24-byte config block at `DAT_0082cfec`:

* If the byte at `req[length - 9]` is `0` (i.e. the request is the
  *last* fragment of a multi-frame label): copy `length - 0x0C` bytes
  from `req[3..]` to `DAT_0082cfec + 0x0D` (a 12-byte name slot at
  the tail of the config block).
* Otherwise (start of a fresh label): clear the 24-byte block, write
  `0xA5 - slot` to `*DAT_0082cfec`, and copy the first 12 bytes of
  `req[3..]` to `pcVar6 + 1`.

In both cases the response echoes the truncated slice and signals
`response[2] = length` so the host can correlate.

#### Display update (`FUN_0082e42c`)

```c
void FUN_0082e42c(text, length, slot_id) {
  if (length != 0) {
    length = min(length, 0x14);
    memset(DAT_0082e498 + 0x26, 0, 0x18);
    *(DAT_0082e498 + 0x26) = slot_id;     // face-slot selector
    memcpy(DAT_0082e498 + 0x27, text, length);
  }
  FUN_008294cc();      // commit config
  FUN_0082e28c();      // render to display
  FUN_008275b6();      // long-press handler (? — also used by 0x08 sub-cmd)
}
```

`DAT_0082e498` is the on-screen face-state block. Writing the
`slot_id` (0xA5..0xA2) selects which of the four face-slots to draw;
the actual label string is at `DAT_0082e498 + 0x27` (20-byte cap).

#### Companion opcode: `0x81` config-chunk write (`FUN_0082cdac`)

The watch-face renderer is paired with a 6-byte config-chunk setter
that persists label updates to flash:

```c
void FUN_0082cdac(param_1) {
  if (memcmp(DAT_0082cfec - 6, param_1, 6) != 0) {  // value changed
    memcpy(DAT_0082cfec - 6, param_1, 6);
    *(DAT_0082cfec + 0x3a) = 1;        // "config dirty" flag
    FUN_008294cc();
    FUN_00840568(param_1);              // flash write
    func_0x0000029c(1, 0xd0);           // 13-second one-shot
  }
}
```

The 6-byte chunk lives at `DAT_0082cfec - 6` (the 6 bytes immediately
preceding the 24-byte `0x18` spill block). Together with the
`FUN_0082cfec + 0x3a` "dirty" flag this forms a small
**shadow-and-flush** persistence layer: the in-RAM `0x18` label is
written immediately, while the 6-byte chunk is only committed to
flash when the host sends a corresponding `0x81` and the value
actually changed.

### 3.6 Opcode `0x43` readDetailSport / per-hour activity dump (`FUN_0082d034`)

Reads detailed sport records (one slot per hour) for a single day
and returns them as a **two-phase multi-frame** Channel-A response:
first a *header* frame carrying the count and end-of-data flag,
then one *record* frame per non-empty slot.

The watch's per-day storage is a fixed 24-slot × 12-byte table
(`auStack_19c` in the handler, size 0x124 = 292 B which is `4 + 24*12`):
the first 4 bytes hold the day's "month index" (the same value
returned by `FUN_008318b0(day)`), the rest is the 24 hourly slots.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `opcode` | `0x43` (consumed by dispatcher) |
| 1 | `day_offset` | 0 = today, 1 = yesterday, … ; `FUN_0082840e() - day_offset` is the day queried |
| 2 | `reserved` | unused |
| 3 | `start_hour` | First slot to scan (`0..23`) |
| 4 | `end_hour` | Last slot to scan (`0..23`); clamped to the current minute-of-day for "today" |
| 5 | `unit_flag` | `0` → durations in 10-second units (legacy "minutes"), `1` → durations in 1-second units |
| 6..14 | unused | — |

#### Phase 1 — header frame

After loading the 292-byte daily block via `FUN_008318b0(day)` (or
zero-fill on miss) and writing the current RTC minute into the
in-progress slot when querying "today", the handler scans slots
`start_hour..end_hour` and classifies each:

| Slot condition | Behavior |
|---|---|
| `status == 0` AND `duration == 0` | Skip (empty) |
| `status == 0` AND `duration != 0` | Count (partial record, duration present) |
| `status != 0` AND `status != 0xFFFF` | Count (in-progress) |
| `status == 0xFFFF` (DAT_0082d438 sentinel) | Skip (finalized — surfaced via the `0x77` activity-summary path instead) |

The header frame is then queued:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x43` | cmd |
| 1 | `0xF0` if any record found, `0xFF` if zero | end-of-data flag |
| 2 | `record_count` (uVar9) | number of valid slots in the range |
| 3 | `unit_flag` echoed (`0x01` if `param_1[5] == 1`) | the host needs this to interpret the per-record duration later |
| 4..14 | 0 | reserved |
| 15 | additive checksum | per §3 |

When the day block is unavailable (`local_1a0 == 0` after the load),
the handler short-circuits with a single error frame
`[0x43, 0xFF, 0, 0, …, 0, cksum]` (13 zero bytes in the payload).

#### Phase 2 — per-record frames

For each counted slot, the handler reads the day's date (BCD-encoded
by `FUN_00828462(month_index, &local_7c)` — three bytes
`{year_off, month, day}`) and emits a 16-byte frame:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x43` | cmd |
| 1 | `year_bcd` | via `FUN_0082ede2(year_off)` (decimal-to-BCD encoder) |
| 2 | `month_bcd` | via `FUN_0082ede2(month)` |
| 3 | `day_bcd` | via `FUN_0082ede2(day)` |
| 4..5 | `record_idx` packed | `(record_idx) | (slot_idx << 2)` — both ≤ 24 |
| 6..7 | 0 | reserved |
| 8..9 | `duration_lo` (u16) | `slot.duration * (10 if unit_flag == 0 else 1)` |
| 10..11 | `slot.aux_u16` (low byte) | second u16 of the slot (e.g. distance / calorie low) |
| 12..13 | `slot.aux_u16 >> 8` | second u16 high byte (one byte of payload only) |
| 14 | `duration_hi` | high byte of the duration u16 |
| 15 | additive checksum | per §3 |

`FUN_0082ede2(v)` is a defensive BCD encoder that returns
`(tens<<4 | units)` for `v ∈ [0, 99]` and `0` otherwise; combined
with `FUN_00828462` it produces a standard
`{year_lo, month, day}` BCD date triplet for the response header.

The host reconstructs the day's full activity trace by collecting
the header (count + flags) and then `count` consecutive `0x43`
record frames. A trailing "no more data" sentinel is the *header's
`byte 1 == 0xF0`* — the record frames themselves do not carry an
EOM marker.

### 3.7 Opcode `0x06` Do-Not-Disturb (`FUN_0082d298`)

Reads and writes the per-device DND state (one enabled flag plus a
start/end window). The handler is the smallest of the "config
get/set" pair in the Channel-A table: a 6-byte DND record, stored
in a private block anchored at `DAT_0082a830 + 0x0E`.

#### Persistent state (6 bytes at `DAT_0082a830 + 0x0E`)

| Off | Field | Notes |
|---:|---|---|
| 0 | `enable` | `0` = off, `1` = on |
| 1..2 | `start_min` (u16 LE) | minute-of-day for the DND window start |
| 3..4 | `end_min` (u16 LE) | minute-of-day for the DND window end |
| 5 | `pad` | reserved; not compared on write |

#### Sub-opcode dispatch (`FUN_0082d298`)

`req[1]` selects read vs write:

| Sub | Action | Helper used |
|---:|---|---|
| `0x01` (read) | Build a 16-byte response, populate bytes 2..6 with the state (1=enabled/2=disabled, then start hour/min, end hour/min), stamp additive checksum, queue via `FUN_0082ebdc`. | `FUN_0082a7e4` |
| `0x02` (write) | Build the new 6-byte state from `req[2..6]`, `memcmp` against the existing 6-byte block, `memcpy` only if changed; queue `req` as the ack response. Calls `FUN_0082a6cc` (UI re-render) and `FUN_0082d4ce(9)` (event broadcast — `9` is the "DND changed" event id). | `FUN_0082a78e` |
| other | no-op (no response queued) | — |

#### Read-path details (`FUN_0082a7e4`)

The read helper normalises the "disabled" flag to a non-boolean code:

* `enable == 0` → emit `0x02` in byte 2 (firmware uses `1 = on`, `2 = off` to leave room for future "always-on" `0` value).
* `enable == 1` → emit `0x01`.
* `start_min` and `end_min` are split into hour/minute using
  `FUN_0083dfba(_, 0x3c)` (returns hour in the low byte, minute in the
  high byte via the `extraout_r1` return slot).

#### Write-path details (`FUN_0082a78e`)

The write helper packs the request into the 6-byte `local_10` block:

```c
local_10 = (u16)(req[3] * 60 + req[4]) |   // start_min  (high u16)
           ((u16)(req[2] == 1) << 0);      // enable     (low u16)
local_c  = (u16)(req[5] * 60 + req[6]);    // end_min    (low u16)
```

It then `memcmp`s the 6 bytes against `DAT_0082a830 + 0x0E` and only
`memcpy`s the new value if anything changed. The two follow-up calls
`FUN_0082a6cc()` and `FUN_0082d4ce(9)` then (a) repaint any DND
indicator on the active face and (b) emit the "DND changed" event
into the watch's internal event ring, where the `0x77` sport-motion
handlers (see §3) pick it up to suppress buzz notifications.

#### Response shapes

For `0x06 0x01` (read):

```
byte  0: 0x06
byte  1: 0x01   (sub-opcode echo)
byte  2: 0x01 (on) | 0x02 (off)
byte  3: start hour    (BCD-less raw u8)
byte  4: start minute
byte  5: end hour
byte  6: end minute
byte  7..14: 0
byte 15: additive checksum
```

For `0x06 0x02` (write), the response is the **request frame echoed
back unchanged** (the host treats it as a 16-byte ack). This is
deliberate: the request is a self-describing ack payload, so the
host can confirm exactly which `(enable, start, end)` triple the
watch committed.

### 3.8 Opcode `0xff` factory reset (`FUN_0082cde8`)

The smallest handler in the Channel-A table: 35 bytes, no response
frame, and a literal "magic word" payload guard.

#### Trigger

The handler accepts the request only when the first three payload
bytes are the ASCII string `"fff"` (`0x66 0x66 0x66`):

```c
if (req[1] == 'f' && req[2] == 'f' && req[3] == 'f') {
    FUN_008275d8();                        // full system reset
    memset(DAT_0082cff0, 0, 0xa4);          // wipe 164 B user config
}
```

Any other payload is a no-op (no response queued, no state change).
The choice of the literal `"fff"` is unusual — it does not match
any normal Oudmon opcodes (0x66 would be in the `0x62..0x67`
"subData[0] sub-opcode set" bucket from `FIRMWARES/_re/FINDINGS.md`)
— so the host can only invoke a factory reset by explicitly
crafting the magic frame, never by accident.

#### Reset sequence

1. `FUN_008275d8()` — the "system reset / re-initialize" routine
   listed in §6: it stops sensors and the motor, tears down and
   re-initialises the BLE stack (`FUN_00827404`, `FUN_0082dfde`),
   zeroes the per-task state, sets `*DAT_00827804 = 5` (a
   re-init "state" sentinel), and arms a 1000 ms one-shot timer
   via `FUN_0082f160(1000)` so the main task restarts cleanly.
2. `memset(DAT_0082cff0, 0, 0xa4)` — wipe the 164-byte user-config
   block at runtime address `0x00208c8c` (literal-pool value
   `0x8c8c2000`).

#### What gets wiped (and what doesn't)

The 164-byte block at `0x00208c8c` is the user-visible config
record (DND, alarm, sedentary, blood-oxygen, UV-touch, etc.).
The factory reset *only* touches this block — it does **not**
clear:

* the BLE pairing table,
* the OTA state machine (`DAT_00830120` / `DAT_00830124`),
* the 0x2b mixture container at `0x00208c76`,
* the RTC time (set by `0x01`),
* the watch-face label at `DAT_0082cfec` (see §3.5).

In other words `0xff "fff"` returns the watch to factory defaults
for the *user-tunable* surface but leaves any committed pairings
and the user's clock alone. This matches the typical "soft
factory reset" semantics expected from a paired wearable.

#### Why no response

The handler is fire-and-forget: the system reset re-initialises the
main task on the 1000 ms timer, so by the time the host would have
parsed a response, the link layer may already be tearing down.
A response frame queued just before the reset would be lost in the
`FUN_0082ebdc` ring during the BLE re-init. The 16-byte request
frame serves as the implicit ack — the host treats the absence of
a follow-up as "reset accepted".

### 3.9 Opcodes `0x25` setSitLong / `0x26` readSitLong — sedentary reminder config

A read/write pair for the "long sit" (sedentary) reminder. The
config is a 6-byte block at `DAT_0082aebc + 0x14`:

| Off | Field | Notes |
|---:|---|---|
| 0 | `start_hour` (u8, 0..23) | hour-of-day the sedentary window begins |
| 1 | `start_min` (u8, 0..59) | minute-of-hour the sedentary window begins |
| 2 | `end_hour` (u8, 0..23) | hour-of-day the sedentary window ends |
| 3 | `end_min` (u8, 0..59) | minute-of-hour the sedentary window ends |
| 4 | `flags` (u8) | enabled / day-of-week bitmap (semantics carried over from the producer) |
| 5 | `interval` (u8, ≤ 60) | nudge interval in minutes, clamped to 60 |

#### `0x26` read — `FUN_0082d258` + `FUN_0082ae84`

```c
void FUN_0082d258() {
    memset(&local_18, 0, 0x10);
    FUN_0082ae84(&local_18);            // populate bytes 1..6
    *(u8*)&local_18 = 0x26;             // byte 0 = cmd
    local_18[15] = FUN_0082b0c4(&local_18, 0xf);
    FUN_0082ebdc(&local_18);
}
```

`FUN_0082ae84` reads the 6-byte block and BCD-encodes each of the
first 4 fields via `FUN_0082ede2` (the same decimal-to-BCD used by
the `0x43` per-hour dump). The response layout is therefore:

```
byte  0: 0x26                (cmd)
byte  1: BCD(start_hour)
byte  2: BCD(start_min)
byte  3: BCD(end_hour)
byte  4: BCD(end_min)
byte  5: flags               (raw u8)
byte  6: interval            (raw u8, ≤ 60)
byte  7..14: 0
byte 15: additive checksum
```

#### `0x25` write — `FUN_0082d284` + `FUN_0082adf4`

```c
void FUN_0082d284() {
    FUN_0082adf4();               // validate + commit the 6-byte block
    FUN_0082adca();               // mark "config dirty" + reset counter
    FUN_0082b986(0x25, 0);        // 1-byte ack
}
```

The 16-byte request frame carries the time fields at **non-standard
positions** (4..9) and in **reverse order** from the read response:

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x25` | cmd |
| 1..3 | unused | (callers may leave 0) |
| 4 | BCD end_min | (reverse order vs read response) |
| 5 | BCD end_hour | |
| 6 | BCD start_min | |
| 7 | BCD start_hour | |
| 8 | `interval` | clamped to `0x3c` (60) if `value - 10 > 0x50` (i.e. > 90) |
| 9 | `flags` | raw u8 |
| 10..14 | unused | |
| 15 | checksum | additive (per §3) |

`FUN_0082adf4` copies the 16-byte request to a stack frame, BCD-decodes
the four time fields with `FUN_0082edc4`, and validates each:

```c
if (start_hour < 0x18 && start_min < 0x3c &&
    end_hour   < 0x18 && end_min   < 0x3c) {
    state[0] = start_hour;        // binary, not BCD
    state[1] = start_min;
    state[2] = end_hour;
    state[3] = end_min;
    state[4] = flags;             // raw from req[9]
    state[5] = interval;          // clamped
    if (memcmp(state, DAT_0082aebc + 0x14, 6) != 0) {
        memcpy(DAT_0082aebc + 0x14, state, 6);
        *(u16*)(DAT_0082aeb8 + 2) = 0;   // reset nudge counter
    }
}
```

If the time fields fail validation, the write is silently dropped
(no ack, no NAK) — the host must ensure the BCD fields are valid.
`FUN_0082adca` then sets `*DAT_0082aeb8 = 1` (a "sedentary-active"
flag the main-loop tick reads) and resets the 16-bit nudge counter
at `*(DAT_0082aeb8 + 2)`.

#### Read/write order asymmetry

The write request encodes the time fields at bytes 4..9 in
*end-first* order, but the read response surfaces them at bytes
1..4 in *start-first* order. This is the same "input is reverse of
output" pattern that appears in the other "config" opcodes
(`0x37` pressure, `0x39` hrv, `0x7a` muslim) and is most likely a
quirk of how the wire format was originally specified for the
H59MA SDK; the host code that ships in `lib/core/protocol/`
should preserve the asymmetry rather than trying to "fix" it on
either side.

### 3.10 Opcode `0x2c` bloodOxygenSetting (`FUN_0082d1c2`)

The simplest "config" handler in the table: a single-bit on/off
flag for the SpO2 (blood-oxygen) sensor, stored as bit 1 of a
shared config byte at `DAT_008277f0 + 0x2D`.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_16 = FUN_00827682()` — read bit 1 of `*(DAT_008277f0 + 0x2D)`, mask `& 3 >> 1` yields `0` or `1` | `FUN_00827682` |
| `0x02` (write) | `FUN_00827660(req[2])` — if the new value differs from the current bit, update the bit in the config byte and call `FUN_0082946e()` (config-changed event broadcast). `local_16 = req[2]` echoes the committed value. | `FUN_00827660` |
| other | `local_16` left at zero; the sub-opcode echo in `local_17` still identifies the request type | — |

#### Persistent state

The SpO2 setting shares one bit of a single config byte at
`DAT_008277f0 + 0x2D`:

| Bit | Field | Notes |
|---:|---|---|
| 0 | (other config — not SpO2) | reserved |
| 1 | `spo2_enabled` | `0` = off, `1` = on |
| 2..7 | (other config) | reserved |

The `& 3` mask in the read path and the `(param_1 & 1) << 1` in the
write path both confirm that only bit 1 is owned by the SpO2
setting; the other 7 bits of that config byte belong to other
features (likely UV-touch or DND; see §3.7 for the DND state
which lives in a different block).

#### Response layout (always 16-byte fragment)

```
byte  0: 0x2C                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02 write)
byte  2: current SpO2 value  (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

The whole 16-byte response is built on the stack from the four
register arguments (`r0..r3`) so that no `memcpy` from the request
is needed — only the three output bytes are touched. The
checksum is computed by `FUN_0082b0c4` over the first 15 bytes
(per the §3 "Common response path") and stamped into `byte 15`
via `CONCAT13`.

#### Why this handler is so short

SpO2 on this watch is a *battery-hungry* sensor: enabling it adds a
continuous PPG read every few minutes. The 1-bit storage means the
state survives the `0xff` factory reset (the parent config byte is
zeroed there) and is fast to toggle from the watch face — the
host's only requirement is that `req[2]` for sub `0x02` be `0` or
`1` (the handler doesn't reject other values, but the bit-mask
write will silently coerce them to `0`/`1`).

### 3.11 Opcode `0x7a` muslim (prayer config) (`FUN_0082cb3a`)

Sub-dispatched by `req[1]`. The "read" path uses a *two-phase* response
(an empty header frame, then a multi-frame payload) via the shared
fragmenter `FUN_0082c988` (see below). The "reset" path is
single-shot.

#### Sub-opcode dispatch

| `req[1]` | `req[2]` | Action |
|---:|---:|---|
| `0x01` | slot_id | **Read** prayer slot. The handler first calls the stub `FUN_00829c88(slot_id, &buf)` — currently a no-op that always returns `0` — so the read always falls into the "slot empty" path and returns a one-byte `0x7A 0xFF` error. See "Stub status" below. |
| `0x02` | `0x01` | **Reset** prayer config: `FUN_00829c90()` (also a stub, currently a no-op). No response. |
| other | any | no-op, no response. |

#### Stub status

Both `FUN_00829c88` (read) and `FUN_00829c90` (reset) are
**unimplemented stubs** in the v14 firmware — they simply `return 0`
or `return`. This means the H59MA v14 firmware does not yet
implement the Muslim prayer feature, even though the opcode is
allocated in the dispatcher table. The handler still wires up the
full "happy path" so that, when the producer side is implemented,
the read will:

1. Send the 16-byte header frame
   `[0x7A, 0x00, 0x05, 0x3C, 0, 0, …, 0, cksum]` (the literal
   `0x3C05007A` little-endian dword at offset 0 with the
   additive checksum on bytes 1..14).
2. Call `FUN_0082c988(0x7A, &local_3d, 0x31)` where
   `local_3d[0] = req[2]` (slot id echo) and bytes 1..48 are the
   prayer-slot payload that the future `FUN_00829c88` will fill
   in.
3. The fragmenter then ships 49 bytes in 13-byte chunks as four
   16-byte frames, sequence-numbered 1..4.

The "send header, then fragmented payload" structure is shared
with `0x37 pressure` and `0x39 hrv` (the other long-response
opcodes in the Channel-A table) — they all reuse
`FUN_0082c988` for the payload.

#### `FUN_0082c988` — 13-byte-chunk fragmented streamer

```c
void FUN_0082c988(byte cmd, byte *data, int length) {
  char seq = 1;
  for (int i = 0; i < length; i += 0xD) {
    memset(&frame, 0, 0x10);
    frame[0] = cmd;
    frame[1] = seq++;
    chunk = min(length - i, 0xD);
    memcpy(&frame[2], data + i, chunk);
    frame[15] = FUN_0082b0c4(&frame, 0xf);
    FUN_0082ebdc(&frame);
  }
}
```

Each 16-byte notify frame carries:

```
byte  0: cmd (0x37 / 0x39 / 0x7A)
byte  1: sequence number (1, 2, 3, …)
byte  2..14: payload chunk (up to 13 bytes)
byte 15: additive checksum
```

For `0x7A` (49-byte payload): ceil(49 / 13) = 4 chunks, sequence
numbers 1..4. The 0x37 / 0x39 callers will use whatever
sequence-length fits their payload. The host decodes by
**collecting all `cmd` frames in order** until it has
`length` bytes or a sentinel — the `FUN_0082c988` itself does
not emit an EOM, so the upper layer is responsible for the
"first frame is the header, follow-up frames are payload
chunks" interpretation.

#### Response layout for the (unimplemented) read path

Phase 1 — header:

```
byte  0: 0x7A
byte  1: 0x00
byte  2: 0x05         (payload size = 5 dwords? — see below)
byte  3: 0x3C
byte  4..14: 0
byte 15: additive checksum
```

The `0x3C` in byte 3 is 60 — the same value seen in `0x37`
pressure's response and in the 0x01 setTime ack. It is the
static "feature-bitmap-shape" byte the firmware reuses across
all "long config" responses; the actual meaning is
producer-specific.

Phase 2 — 4-frame fragmented payload (one per 13-byte chunk):

```
frame N (N=1..4):
  byte  0: 0x7A
  byte  1: N
  byte  2..14: slot data chunk
  byte 15: additive checksum
```

The slot data layout is currently unknown because
`FUN_00829c88` is a stub; once the prayer feature ships, byte
0 of the data will identify the slot id (echo of `req[2]`)
and bytes 1..48 will hold the per-slot prayer record
(prayer name, time, offset, etc.).

### 3.12 Opcode `0x15` readHeartRate (`FUN_0082cf48`)

Heart-rate record read by *index* (not by timestamp). The handler
takes a 4-byte index from the request, converts it to a record
timestamp, and ships the matching 292-byte HR record back as a
two-phase response (header + fragmented payload) using the same
13-byte-chunk streamer shape as `0x7a` (§3.11), `0x37` and `0x39`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x15` | cmd (consumed by dispatcher) |
| 1..4 | `index` (u32 LE) | record index; `0` = "current/latest" sentinel |
| 5..14 | unused | — |

#### Index → timestamp conversion

```c
uint32_t local_13c = req[1] | (req[2] << 8) | (req[3] << 16) | (req[4] << 24);
uint32_t timestamp;
if (local_13c == 0) {
    timestamp = 0;
} else {
    FUN_008279c4(local_13c, &timestamp);   // month-index → seconds
}
int found = FUN_00833c92(timestamp, data);
```

The conversion helper `FUN_008279c4` is the same month-index → epoch
helper used by `FUN_00828390` (see §3.4 setTime). The 4-byte index
therefore acts as a *date* packed in the same way the `0x01` setTime
BCD date struct is decoded — typically `year_lo | (month << 8) | (day << 16) | (slot << 24)`, where `slot` picks the n-th HR record
stored for that day.

#### Phase 1 — header / error

* If `FUN_00833c92` returns 0 (no record at that timestamp): send
  a single 16-byte error frame

  ```
  byte  0: 0x15
  byte  1: 0xFF              (error flag)
  byte  2: 0x14              (status code 20)
  byte  3..14: 0
  byte 15: additive checksum
  ```

  The static dword `0x140000FF15` (little-endian) is the
  watch's universal "no data at this index" ack.

* If `FUN_00833c92` returns 1 (record exists): send a 16-byte
  **header** frame first

  ```
  byte  0: 0x15
  byte  1: 0x18              (24 — payload size lower byte)
  byte  2: 0x80
  byte  3: 0x05
  byte  4..14: 0
  byte 15: additive checksum
  ```

  The header is the literal dword `0x5180015` (LE) — same
  "feature-bitmap-shape" reuse as the `0x7a`/`0x37`/`0x39` headers
  (see §3.11). It tells the host "data follows, this many bytes
  total".

#### Phase 2 — fragmented payload (23 frames)

The 292-byte record (73 × u32) is then fragmented into
`ceil(292 / 13) = 23` 16-byte notify frames using the same
inlined chunk loop as `FUN_0082c988`:

```c
char seq = 1;
for (i = 0; i < 292; i += 13) {
    frame[0] = 0x15;
    frame[1] = seq++;
    chunk = min(292 - i, 13);
    memcpy(&frame[2], data + i, chunk);
    frame[15] = FUN_0082b0c4(&frame, 0xf);
    FUN_0082ebdc(&frame);
}
```

The first u32 of the response data (`data[0]`) is **overwritten
with the request index** before fragmentation (`local_138[0] =
local_13c`), so the host sees its own `index` echoed back as the
4-byte prefix of the payload. The remaining 72 u32s
(`data[1..72]`) are the raw HR record: typically 24 hours × 3
fields (HR value, RR-interval, motion flag) packed into u32s,
but the producer side is owned by `FUN_00833c92` and not detailed
in the firmware body.

#### Frame layout per chunk

```
byte  0: 0x15              (cmd echo)
byte  1: N                (sequence: 1..23)
byte  2..14: 13 bytes of record data
byte 15: additive checksum
```

The last frame is padded with zeros (the data buffer is 292 B but
the last chunk only carries 292 - 22*13 = 6 real bytes followed by
7 zero padding bytes).

#### Host decode recipe

1. Read the header frame; expect byte 0 = `0x15` and byte 1 = `0x18`.
2. Collect follow-up frames with byte 0 = `0x15` and sequence
   numbers `1, 2, …`. Concatenate bytes 2..14 of each frame in
   order until 292 B are accumulated.
3. The first 4 B of the concatenated buffer is the request index
   (echo); bytes 4..291 are the HR record.

### 3.13 Opcode `0x1e` realTimeHeartRate (`FUN_0082d20c`)

A 3-sub-opcode controller for the watch's *real-time* (continuous)
heart-rate measurement. The "is running" flag and the 60-second
countdown are packed into a single byte at `DAT_0082d43c + 8`
(runtime `0x00208d30`).

#### Sub-opcode dispatch

| `req[1]` | Condition | Action |
|---:|---|---|
| `0x01` (start) | `cVar2 == 0` (idle) | `*(DAT_0082d43c + 8) = 0x3C` (60-second counter reload); `FUN_0083371e(0x2000)` (HR driver start in continuous mode); `func_0x00013694(DAT_0082d440, 1000)` (start 1 s tick timer) |
| `0x02` (stop) | `cVar2 != 0` (running) | `*(DAT_0082d43c + 8) = 0` (counter to zero); `FUN_00833704()` (HR driver stop); `func_0x000136bc(DAT_0082d440)` (cancel 1 s tick timer) |
| `0x03` (reset) | `cVar2 != 0` (running) | `*(DAT_0082d43c + 8) = 0x3C` (counter back to 60, but no driver re-start and no timer re-arm) |
| other | any | no-op (handler does not branch) |

The sub-opcode × condition gate prevents double-starts and
double-stops; `0x01` on an already-running measurement is silently
ignored, and `0x02` on an idle measurement is also a no-op. The
handler never sends a response frame (it is one of the few
*fire-and-forget* Channel-A commands).

#### Persistent state

A single byte at `DAT_0082d43c + 8` (runtime `0x00208d30 + 8`)
doubles as both the "is running" flag and the 60-second countdown:

| Value | Meaning |
|---:|---|
| `0` | measurement idle |
| `0x3C` (60) | running, 60 s remaining (reloaded on start and on `0x03`) |
| `1..0x3B` | running, that many seconds remaining (decremented by the 1 s tick) |

The countdown is **not** decremented by the handler — the watch's
1-second tick (`func_0x00013694` with 1000 ms period, anchored at
`DAT_0082d440` runtime `0x00209f40`) calls into the HR driver
each tick, and the driver itself is what writes the decremented
value back to `*(DAT_0082d43c + 8)`. When the value reaches `0`
the measurement is auto-stopped by the driver and the timer
naturally falls out of its re-arm loop.

#### HR driver calls

`FUN_0083371e(mode = 0x2000)` (start) builds the 8-byte request
`{cmd = 0x10003, mode = 0x2000}` and forwards it to the HR driver
via `FUN_008273d0(&req, 0x17C)`. The `0x17C` is the HR driver
sub-command id for "start measurement", and `0x2000` selects
*continuous* mode (as opposed to `0x0800` used by the `0xa1`
factory test mode for one-shot measurement).

`FUN_00833704()` (stop) builds `{cmd = 0x20003, mode = 0x2000}`
and forwards via `FUN_008273d0(&req, 0x174)`. The `0x174` is the HR
driver sub-command id for "stop measurement". Both sub-commands
live in the same driver wrapper `FUN_008273d0` and are part of the
"VC_HRV_16Bit_integration_6.0_addRMSSD" library mentioned in
`firmwares/_re/strings-mining/findings.txt`.

#### Sub-opcode `0x03` semantics

`0x03` is "reset the 60 s countdown back to 60 without
re-starting the measurement". A host can use it to extend a
measurement window indefinitely by sending `0x03` every 55 s.
Unlike `0x01` it does **not** call the HR driver or arm the
1 s tick — those are assumed to still be running — it just
reloads the countdown byte. This makes `0x03` a no-op if the
measurement has already auto-stopped (the `cVar2 != 0` guard
suppresses the write in that case).

#### Why no response

The 1-second tick + HR driver are real-time; queuing a response
frame in the `FUN_0082ebdc` ring would add a multi-ms latency
to the very-fast feedback loop the host uses to update its
live-HR UI. The watch treats the sub-opcode as a "set" command
and lets the host poll the current HR value separately (the
real-time HR notifications travel on the `0x2b`/`0x39` and
related push paths, not through this opcode).

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

#### Deeper behaviour (decompiled)

The handler uses **two global state buffers** to coordinate
the factory-test sequence:

* `DAT_00828108` — a "scratch" buffer (about 40 bytes) used
  for transient context (counts, sub-byte echo, current
  HR mode parameter).
* `DAT_0082810c` — a "live" buffer holding the saved sensor
  state (step count, HR mode, body position, etc.). The
  handler reads/writes the `DAT_0082810c + 4..0xC` range to
  push or pull the state.

The four "interesting" paths:

* **`sub 0x01` — full reset**:
  1. `FUN_00827ba6(2)` — stop sensors / motor.
  2. `FUN_0082949c()` — save the *current* state from
     `DAT_0082810c + 4..0xC` into the scratch buffer
     `DAT_00828108 + 0x1C..0x24`.
  3. `FUN_00833e86()` + `FUN_00831b90()` +
     `thunk_FUN_00831230()` + `FUN_00827940()` — generic
     "clear step data + reset BLE + reset task" cleanup
     sequence (the same routine as `0xff factory reset`).
  4. Re-stage the scratch buffer back into the live buffer
     (so the saved state survives the reset).
  5. Zero out the deferred ring (`FUN_00833948`).
  6. Stop HR with `DAT_00828110` (mode = `0x40`).
  7. Re-arm HR with `0x40`.
  8. Echo `req[2]` into `DAT_00828108[0]` and queue a
     1000 ms worker via `FUN_00829c24`.
  9. Tail-call `FUN_00827dba(0)` — the state-update worker
     that pushes the live state to the notify ring (see
     §8.16).

* **`sub 0x02` — restore**:
  1. If `DAT_0082810c[8]` (the "save state present" flag)
     is non-zero, copy the scratch state back into the live
     buffer.
  2. If `DAT_0082810c[1]` (the "save count present" flag)
     is non-zero, copy the scratch step count back.
  3. Stop HR, re-arm with `0x40`.
  4. Tail-call `FUN_00829c50` to cancel any pending workers.

* **`sub 0x04` — start HR mode `0x800`**:
  Just calls `FUN_0083371e(0x800)` and stores `req[2]` in
  `DAT_00828108[0]` for the worker.

* **`sub 0x06` — save + reset**:
  Similar to `0x01` but **without** calling `FUN_00827ba6(2)`
  first — leaves the sensors running while saving the
  state, then triggers a state-update worker that pushes
  the live state and resets the deferred ring.

#### `FUN_00827dba` — state-update worker

The worker called by all four "interesting" paths above:

```c
void FUN_00827dba() {
    rsp[0] = 0xA1;  // cmd
    rsp[1] = 1;     // sub-cmd echo (= the sub-byte from the request)
    rsp[2..3] = FUN_00833968();          // 2-byte u16 "state version" id
    rsp[4..7] = *(u32*)(DAT_00827e8c + 0x4C);  // 4-byte live state field
    rsp[8..11] = *(u32*)(DAT_00827e8c + 0x48); // 4-byte live state field
    rsp[12..14] = uVar11;                // low 12 bits of *(DAT_00827e8c + 0x50)
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push 16-byte state-update frame
    rsp[0] = 0xA1;
    rsp[1] = 2;     // sub 2 = "step count"
    rsp[2..3] = FUN_00833960();          // 2-byte step count u16
    rsp[4..5] = *(u16*)(DAT_00827e8c + 0x40); // step count u16
    rsp[6..7] = *(u16*)(DAT_00827e8c + 0x3E); // last-step u16
    rsp[8..9] = uVar9;                    // 2-byte "last update" timestamp
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push step-count frame
    rsp[0] = 0xA1;
    rsp[1] = 3;     // sub 3 = "body position / motion"
    rsp[2..3] = local_1c[0];  // 2-byte motion u16 (from FUN_00832f1e)
    rsp[4..5] = local_18[0];  // 2-byte body position u16
    rsp[6..7] = local_20[0];  // 2-byte fall-detect u16
    rsp[15] = checksum;
    FUN_0082ebdc(rsp);  // push motion frame
    if (*DAT_00828108 == '\x04') {
        FUN_0082a460(2000);  // 2-second delay
    } else {
        // ... increment retry counter, reschedule worker ...
    }
}
```

The worker pushes **three frames** back-to-back:
* `sub 1`: live sensor state (2 B version + 4 B + 4 B + 3 B
  partial state)
* `sub 2`: step count (2 B + 2 B + 2 B)
* `sub 3`: motion / body position (3 × 2 B)

These are the three "live" snapshots the host needs to render
the factory-test UI. The `sub 0x04` path (`*DAT_00828108 ==
4`) inserts a 2-second delay between frames so the host has
time to render each before the next one arrives; the
default path re-schedules the worker until `sub == 4` or the
retry counter exceeds 120 iterations.

#### Why `sub 0x01` saves + clears + restores

The full-reset sequence in `sub 0x01` is **idempotent**:
it saves the current state *before* the reset, then clears the
step counter, then restores the saved state. This means the
factory operator can send `sub 0x01` repeatedly during a
test session to "re-zero" the counter without losing the
configuration. The `DAT_00828108 + 0x1C..0x24` scratch
buffer holds the saved state across the reset; the live
buffer (`DAT_0082810c + 4..0xC`) is re-staged after the clear.

#### Pair with `0xce` vendor/test (0xFEE7)

`0xa1` (Channel-A) and `0xce` (0xFEE7) are *both* factory-test
entry points but on **different transports**. `0xa1` is the
public Channel-A path used by host SDKs; `0xce` is the OEM
vendor path used by factory-floor equipment (§8.10). They
share *some* helpers (`FUN_0083371e`, `FUN_00833704`,
`FUN_0082a460`) but call different state-update paths
(`FUN_00827dba` vs `FUN_00838bc0`/`FUN_00833400`).

A factory operator with the OEM tools would use `0xce`; an
OpenWatch host SDK would use `0xa1`. The two paths do not
interfere with each other.

### 3.14 Opcode `0xc6` restoreKey (device reboot)

Unlike the other Channel-A opcodes that route to dedicated
handler functions, `0xc6` is a *special* case handled inline in
the main dispatcher `FUN_0082d2dc`. The handler takes a one-byte
sub-command at `req[1]` and either runs a full reboot sequence
or sends a one-byte ack, depending on the sub-command.

#### Sub-command dispatch (inline in `FUN_0082d2dc`)

```c
if (opcode == 0xc6) {
    if (req[1] == 'l') {                          // 0x6C — full reboot
        FUN_008275d8();                            // §6 system reset
        FUN_00829504();                            // clear 224 B main state
        FUN_00829560();                            // clear 164 B user config
        FUN_0082f160(2000);                        // 2 s wakeup timer
        FUN_0082a460(1000);                        // 1 s UI delay
    } else {
        FUN_0082b986(0xc6, 1);                     // 1-byte ack (|0x80 high-bit)
    }
}
```

The 0x6C magic byte is the *only* byte in the request that
matters; the rest of the 16-byte frame is ignored. Any other
value of `req[1]` returns a one-byte ack `[0xC6, 0, 0, …, 0, cksum]`
via `FUN_0082b986(cmd, isNotify=1)` — the high bit of `0xC6` is
already set so the `| 0x80` is a no-op.

#### The `0x6C` reboot sequence

| Step | Function | Effect |
|---:|---|---|
| 1 | `FUN_008275d8()` | System reset (the same routine used by `0xff` factory reset): stops sensors and motor, tears down the BLE stack via `FUN_00827404` + `FUN_0082dfde`, zeroes per-task state, sets `*DAT_00827804 = 5`, and arms a 1000 ms one-shot timer via `FUN_0082f160(1000)`. |
| 2 | `FUN_00829504()` | Clear 224 B of main-app state. The body is `memset(stack, 0, 0x1FC)`, load the 4-byte u32 at `*(DAT_008297dc + 4)`, then call `func_0x00007b32(&u32, 0, 0xE0)` (likely a state-store clear for the *first* state block). |
| 3 | `FUN_00829560()` | Clear 164 B of user-config. The body is `memset(stack, 0, 0x200)`, then `func_0x00007b32(stack, 0x200, 0xA4)` (the *same* 0xA4-byte config block that `0xff` factory reset wipes via `DAT_0082cff0`; the 0x6C reboot path *additionally* wipes it). |
| 4 | `FUN_0082f160(2000)` | Start a 2000 ms one-shot timer. |
| 5 | `FUN_0082a460(1000)` | Start a 1000 ms UI delay. The body checks `FUN_00828b1e()` (no pending activity) and `FUN_0082a826()` (on home screen) before running, cancels any active timer at `DAT_0082a69c + 4`, starts a new 1000 ms timer, calls `FUN_0082a382(0x4B)` (probably a "shutting down" UI event), and sets `*(DAT_0082a69c + 0xc) = 1` (the "delaying" flag). |

#### `0x6C` vs `0xff 'fff'` — what's the difference?

Both opcodes trigger a system reset (`FUN_008275d8`) and end up
zeroing the 0xA4-byte user-config block, but:

| | `0x6C` reboot | `0xff 'fff'` factory reset |
|---|---|---|
| System reset (`FUN_008275d8`) | yes | yes |
| Main-app 224 B state wipe | **yes** (`FUN_00829504`) | no |
| 164 B user-config wipe | **yes** (`FUN_00829560`) | yes |
| 2000 ms wakeup timer | **yes** | no |
| 1000 ms UI delay | **yes** | no |
| "shutdown" UI event (`0x4B`) | **yes** | no |
| Response | none (BLE torn down) | none (BLE torn down) |
| Trigger | single byte `0x6C` | three-byte magic `"fff"` |

In other words, `0x6C` is the "**reboot and start clean**" command
the host sends when it wants the watch to come back up with no
in-RAM state at all, while `0xff 'fff'` is the "**reset user
preferences but keep the running app state**" command. A normal
host-initiated "reboot the watch" session uses `0x6C`; a
"factory-reset to clear my customisations" session uses
`0xff 'fff'`.

#### Why no response

The reboot path tears down the BLE stack at step 1 (`FUN_0082dfde`
inside `FUN_008275d8`), so any response frame queued by the
dispatcher would be lost in the `FUN_0082ebdc` ring during the
re-init. The 16-byte request is the implicit ack. The host treats
the loss of the link as the success indicator and waits for the
watch to re-advertise before sending a fresh `0x01`/`0x48`
handshake.

### 3.1 Opcode `0x2b` menstruation / mixture container

The `0x2b` handler (`FUN_0082ba54`) backs a 16-byte persistent record on the
device. The record is anchored at a runtime pointer stored in the literal
pool slot `DAT_0082b0b8` (value `0x00208c7c`). Functions that touch the
record refer to it via negative or positive byte offsets relative to that
pointer; in the layout below **byte 0** of the record lives at
`DAT_0082b0b8 - 6` (= `0x00208c76`).

### 3.15 Opcode `0x08` findDevice / long-press branch (inline in `FUN_0082d2dc`)

Like `0xc6` (see §3.14), the `0x08` opcode is *special-cased inline*
in the main dispatcher `FUN_0082d2dc` rather than routed to a
dedicated handler. It owns three distinct user-visible features
on the H59MA: **find-device** (vibrate the watch to help the user
locate it from the host), the **camera-shutter remote** path (a
side-effect of the find-device sequence), and the **long-press**
key sequence that powers off the watch.

#### Sub-cmd dispatch

```c
if (opcode == 0x08) {
    cVar2 = req[1];
    if (cVar2 == 0)      FUN_008275b6();        // cancel find
    else if (cVar2 == 1) FUN_00827516();        // start find
    else if (cVar2 == 0xAB && req[2] == 0xDC) { // long-press magic
        FUN_00827ba6(3);
    } else {
        if (FUN_008280fe() == 2) goto end;      // screen state guard
        FUN_00827ba6(2);                         // set motor mode 2
    }
}
```

So `req[1]` selects the action and `req[2]` carries an extra
"modifier" that only matters for the long-press case. Any sub-cmd
other than `0x00`, `0x01`, or `0xAB` falls into the
"set motor mode" branch, which is itself a no-op when
`FUN_008280fe() == 2` (the screen-state byte at
`DAT_0082810c - 0x3c` indicates the user is already in the
target mode).

#### `0x08 0x00` — cancel find / power-off (`FUN_008275b6`)

```c
void FUN_008275b6() {
    FUN_00827404();   // reset BLE
    FUN_0082dfde();   // re-initialise BLE
    FUN_0082fd9c();   // reset some state
    FUN_008274fa(2);  // motor: stop pattern
    FUN_0082954a();   // reset UI
    FUN_0082f160(2000);  // 2-second timer
}
```

Cancels the find-device pattern, tears down and re-initialises the
BLE stack, and arms a 2-second one-shot timer. The same body is
also invoked by the long-press power-off path (`0x72` pushMsgUint
helper `FUN_0082e42c` from §3.5), making `0x08 0x00` the canonical
"stop everything and wait 2 s" entry point.

#### `0x08 0x01` — start find (`FUN_00827516`)

The most complex of the four branches. Drives the watch into
find-device mode: vibrate + beep, then poll for a button press
within 1 s.

```c
void FUN_00827516() {
    if (FUN_00828af4() != 0) return;   // bail if HR step counter running
    FUN_0082a460(1000);                // 1 s UI delay
    *DAT_00827804 = 1;                 // state sentinel
    FUN_00827432();                    // reset BLE TX
    FUN_00827404();                    // reset BLE
    func_0x00013146(100);              // 100 ms delay
    FUN_0082994c(0xd2, 2, 3);          // alert (3 args — vendor profile)
    FUN_0082954a();                    // reset UI
    FUN_008274fa(1);                   // motor: pattern #1
    uint32_t start = FUN_00827994();   // read RTC start
    while (FUN_00829a4e() != 0) {      // while motor still running
        if (FUN_00827994() - start > 1000) break;  // up to 1 s
        func_0x00013146(100);
    }
    thunk_FUN_00837b42();              // stop motor
    FUN_0082928c();                    // reset UI
}
```

Key observations:

* The `FUN_00828af4() != 0` early-out is the **HR step counter
  guard**: if the user is currently recording a sport session,
  the find-device sequence is silently dropped so the vibration
  doesn't disturb the step-count reading.
* The 1 s ceiling is enforced by polling the RTC (`FUN_00827994`)
  every 100 ms (`func_0x00013146(100)`); the loop breaks on
  either the motor naturally finishing (`FUN_00829a4e() == 0`)
  or the 1 s timeout.
* The `FUN_0082994c(0xd2, 2, 3)` is the *vendor* alert pattern
  (`0xd2 = 210`), distinct from the `0x12` and `0x1F` patterns
  used by `0x50 'P'` (§8) and `0xc7` (§3.2).
* The end-of-pattern cleanup always runs even if the timeout
  fired (`thunk_FUN_00837b42` + `FUN_0082928c`), so the motor
  cannot be left running after find-device returns.

#### `0x08 0xAB 0xDC` — long-press magic

A 2-byte magic gate (`0xAB 0xDC` at `req[1..2]`) that selects the
*power-off / shutdown* variant. The handler only sets the
vibration/motor mode register to `3`:

```c
void FUN_00827ba6(int mode) {
    if (*(int *)(DAT_00827e8c + 4) != mode) {
        *(int *)(DAT_00827e8c + 4) = mode;
        FUN_008294cc();        // commit config
    }
}
```

`DAT_00827e8c + 4` is the `vibration_mode` byte that the
`FUN_008275b6` cancel-find sequence then *consumes* on the next
0x08 0x00. Mode `3` is the "power-off" preset; the actual
shutdown (BLE teardown, sensor stop) is the same `FUN_00827404` +
`FUN_0082dfde` + 2 s timer sequence already documented above.

#### Default branch — motor mode 2

For any other sub-cmd (e.g. the host sends `0x08 0x02`, `0x08 0x03`,
etc.) the dispatcher sets the motor mode to `2` ("normal alert"
preset) provided the screen state isn't already in that mode.
The guard `FUN_008280fe() == 2` reads the byte at
`DAT_0082810c - 0x3c` — when that byte is `2` the call is
skipped entirely (a host trying to set the mode it's already
in is a no-op).

#### Companion: the screen-state byte (`FUN_008280fe`)

```c
undefined1 FUN_008280fe() {
    return *(undefined1 *)(DAT_0082810c - 0x3c);
}
```

This 1-byte read is the watch's "current screen / app state"
indicator. The `0x08` default branch uses it to suppress
redundant motor-mode writes; the same byte is presumably
referenced by other handlers in the camera-shutter and
long-press sequences. The exact value-2 meaning ("motor-mode
already in target state") is recovered by the dispatcher logic
itself rather than from a string constant.

#### Record layout (`mixture_state_t`, 16 bytes)

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
| `0x00839e4e` | `FUN_00839e4e` | `ancs_add_client` — registers ANCS client, allocates 0x114-byte per-client state |
| `0x0083a116` | `FUN_0083a116` | `ancs_client_cb` — handles ANCS lifecycle events — see §4.1 |
| `0x00839fee` | `FUN_00839fee` | NotificationSource data parser — see §4.2 |
| `0x0083a036` | `FUN_0083a036` | GetAppAttributes follow-up requestor — see §4.3 |

The watch implements an ANCS client so iOS notifications can be pushed
to the screen via opcode `0x72`.

### 4.1 ANCS client callback (`FUN_0083a116`)

Lifecycle dispatcher. Receives `(ctx, client_idx, event_ptr)` from the
GATT stack and switches on the first byte of `event_ptr` (the
"event_id" of the ANCS client wrapper). The handler is the only
entry point that touches the per-client state at
`client_idx * 0x114 + state_base + 4`.

#### Event dispatch

| `event_id` | Action |
|---:|---|
| `0` (connect) | Sub-classified on `event[4]`: `2` → `func_0x00005aa8(..., connect_log, 0)` + `FUN_008399ec(client_idx, 1)`; `3` → log a different "bind" line. Both fire a debug log line; neither changes state. |
| `1` (notification) | If `event[6]` (data length) is non-zero, enable the ANCS notification subscription via `func_0x00005aa8(..., notif_subscribe_log, 1)`. Then dispatch on `event[4]` (notification action byte) via a switch8 table at `0x83a1b5` (16 entries) — see below. |
| `2` (data) | Sub-classified on `event[4]`: `0` (NotificationSource) → `FUN_00839fee(client_idx, event+8, event[6])`; `1` (AppAttribute) → log + `FUN_0083a036(client_idx, event+8, event[6])`. |
| `3` (disconnect) | Log the disconnect, then `memset(client_state, 0, 0x114)` to wipe the per-client state. The 4 bytes at `state_base + 4` (a u32 reference, e.g. an attribute handle) is preserved across the wipe. |

#### Notification sub-dispatch (`event_id == 1`, switch8 at `0x83a1b5`)

The 16-entry ARM-Thumb switch8 table (base `0x83a1b5`, format
`u8 half-offset`) decodes the `event[4]` (ANCS "NotificationAction")
into per-action handlers:

| Action | Handler target | Notes |
|---:|---|---|
| `0` | `0x83a1bd` | "added" — likely records the notification UID and starts attribute fetch |
| `1` | `0x83a1c5` | "modified" — re-records the UID |
| `2` | `0x83a1cd` | "removed" — clears the UID slot |
| `3` | `0x83a1e3` | "action" — iOS 12+ "press/release" action dispatch |
| `4` | `0x83a1f1` | "category" — extract category byte for routing |
| `5` | `0x83a24d` | reserved (out of range) |
| `6` | `0x83a1b5` (default) | no-op |
| `7` | `0x83a255` | "sub-action" — secondary press/release routing |
| `8` | `0x83a247` | secondary "modified" |
| `9` | `0x83a1b5` (default) | no-op |
| `10` | `0x83a1f9` | "fetch-attrs" — request `GetAppAttributes` for the new UID |
| `11` | `0x83a225` | app-attribute response |
| `12` | `0x83a217` | reserved / debug |
| `13` | `0x83a1d7` | "press-only" action |
| `14` | out-of-function (default) | falls into the default slot |
| `15` | `0x83a251` | "release-only" action |

The actual per-action bodies are tiny thunks (each ~6 instructions)
that call the same downstream parsers as the `event_id == 2` path.

### 4.2 NotificationSource data parser (`FUN_00839fee`)

Called from the `event_id == 2, event[4] == 0` path with
`(client_idx, data_ptr, data_len)`. Logs the raw length, then
accumulates bytes into the per-client state starting at
`client_idx * 0x114 + state_base`:

```c
void FUN_00839fee(int client_idx, char *data, int data_len) {
  log("notif_src", client_idx, data_len);
  state = client_idx * 0x114 + state_base;
  if (*state == 0) {                       // first fragment
    if (data_len != 0 && *data == 0) *state = 1;   // accept start-of-frame
  } else if (*state > 15) {
    return;                                // capacity cap
  }
  FUN_00839f30(state, data, data_len);     // append to state buffer
}
```

The per-client state is laid out so that `state[0]` is a 1-byte
fragment counter / flag; subsequent bytes are the raw
NotificationSource payload (EventID u8, Flags u8, CategoryID u8,
CategoryCount u8, NotificationUID u32 — 8 B of header, then
optional component IDs). The cap at `> 15` matches the worst-case
header + 7 component bytes.

### 4.3 GetAppAttributes follow-up (`FUN_0083a036`)

Called from the `event_id == 2, event[4] == 1` path with
`(client_idx, data_ptr, data_len)`. Only acts on the canonical
8-byte `cmd=0x1A` "Get App Attributes" frame:

```c
if (data_len != 8) return;
cmd_id   = data[5];      // 0/1/4/6/7 = attr we are requesting
attr_id  = data[0];      // must NOT be 2 (AppIdentifier — already known)
if (attr_id == 2) return;
```

The handler then builds the 14-byte
`{cmd=0x1A, notif_uid=u32, attr_mask=u16, pad=6x u8}` request
covering attribute IDs 0..7 (display name, subtitle, message,
date, positive action label, negative action label, reserved,
reserved) and submits it via `func_0x00012e82` /
`FUN_00839a3e`. On success (`func_0x00012ed6 == 0`) it logs a
debug line; on failure it logs the error and returns.

This is the "second-stage" parser: when a notification arrives
with a UID the watch has not seen before, the ANCS layer issues a
GetAppAttributes request to fetch the human-readable app name (and
optionally subtitle/message) before queuing the push on the
Channel-A `0x72` path.

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

### 8.1 0xFEE7 dispatcher (`FUN_0082c944`)

The actual opcode table for the 0xFEE7 service. The function is
called from `FUN_0082e87a` (the GATT write handler) with
`(frame_ptr, frame_length)`.

#### Top-level guards

```c
void FUN_0082c944(byte *param_1, int param_2) {
    if (*DAT_0082caec == 0x01) return;   // §8.1 service-suspended flag
    if (param_2 != 0x10) return;         // 16-byte frame only
    if (*param_1 != 0x43 && *param_1 != 0x48)
        FUN_0082eebe();                  // keep-alive timer reset
    // ... opcode dispatch ...
}
```

The `*DAT_0082caec == 0x01` check is the watch's *service-suspended*
flag (set by `0xC5/0xC8/0xC9` config writes — see §8.1 below).
The keep-alive reset skips the "read-only" opcodes `0x43 'C'` and
`0x48 'H'` (the host handshake/keep-alive pair) so an idle host
polling the link does not bump the timer.

#### Opcode → handler map (reverse-engineered from `FUN_0082c944`)

| Opcode(s) | Handler | Notes |
|---|---|---|
| `0x00..0x2a` | Low-range `switch8` at `0x82c61c` (39 cases + default) | Per-entry thunk — detailed below |
| `0x2b, 0x37, 0x38, 0x3a, 0x3b, 0x43 'C', 0x72, 0x77, 0x7a, 0x7d, 0x81, 0xa1, 0xc6, 0xc7 'D', 0xff` | Deferred-command ring | `FUN_0082be64` |
| `0x36` | Heart-rate related read/set | `FUN_0082c112` — see §8.8 |
| `0x39` | HRV setting | `FUN_0082c9da` |
| `0x3c` | Fixed capability block `[0x3c,0,0x40,0xa0,0x20,…]` | `FUN_0082c50e` — see §8.12 |
| `0x3e` | Lipids read/set (bit 7 of shared config byte) | `FUN_0082c550` | see §8.15 |
| `0x48 'H'` | Handshake — 15-byte device-info block | `FUN_0082bf40` — see §8.2 |
| `0x50 'P'` | **Inline** alert: `FUN_0082994c(0x14,0x10,1,0x19)` + `FUN_0082a5c8(8)` (motor + UI) | inline |
| `0x51 'Q'` | "Find phone" / alert trigger | `FUN_0082c5b8` — see §8.11 |
| `0x60` | Status-field write (`DAT_0082bfd4 + 0x2c`) | `FUN_0082be90` | see §8.16 |
| `0x61 'a'` | Status response (battery / daily counters) | `FUN_0082bee6` — see §8.3 |
| `0x69 'i'` | Multi-step mode control (start/stop/cancel) | `FUN_0082c2f4` — see §8.5 |
| `0x6a 'j'` | Continuation of `0x69` mode control | `FUN_0082c1e2` |
| `0x7b, 0xb0, 0xc2, 0xcc, 0xf0, 0xf1` | No-op (early return) | — |
| `0x90` | Echo `[0x90]` (self-marker) | `FUN_00827ad2` — see §8.6 |
| `0x91` | Echo `[0x91]` | `FUN_00827aee` |
| `0x92` | (handler) | `FUN_00827b14` |
| `0x93` | (handler) | `FUN_00827c4a` |
| `0x94` | (handler) | `FUN_00827b2e` |
| `0x95` | (handler) | `FUN_00827b54` |
| `0x96` | Sends `[0x96,0,0,0x96,…]` and resets state | `FUN_00827b7c` — see §8.4 |
| `0x97..0xa0` | High-range `switch8` at `0x82c6e0` (10 cases + default) | Per-entry thunk — detailed below |
| `0xbf` | (handler) | `FUN_0082ba94` |
| `0xc0` | (handler) | `FUN_0082bb0c` |
| `0xc1` | Sends a long/fragmented response: `FUN_008337fa(DAT_0082caf0)` + `FUN_0082b938(*param_1, DAT_0082caf0, 1)` | inline |
| `0xc3` | If `param_1[2] == 1` → `FUN_0082dfde()`; then drive OTA state machine via `FUN_0082fe52(4 or 0, 0)` based on `param_1[1]` (1=push 4, 2=push 0, other=return) | inline |
| `0xc4` | No-op | `FUN_00830462` |
| `0xc5` | If `param_1[1] == 1` → `DAT_0082caec[3] = 1`; else `DAT_0082caec[3] = 0` | inline |
| `0xc8` | Same as `0xc5` but writes `DAT_0082caec[4]` | inline |
| `0xc9` | `DAT_0082caec[5] = param_1[1]` | inline |
| `0xcd` | Byte-reverse echo of req[3..6] (link sanity test) | `FUN_0082be12` — see §8.9 |
| `0xce` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) | `FUN_0082bcde` — see §8.10 |
| `0xfe` | `FUN_00844214(*(u16*)(param_1 + 1))` — vibration pattern from a duration arg | inline — see §8.13 |
| other | Vendor NAK: `FUN_0082bcba(opcode)` | `FUN_0082bcba` |

#### Deferred-command ring (`FUN_0082be64`)

The opcodes routed to `FUN_0082be64` (`0x2b`, `0x37`, `0x38`,
`0x3a`, `0x3b`, `0x43 'C'`, `0x72`, `0x77`, `0x7a`, `0x7d`,
`0x81`, `0xa1`, `0xc6`, `0xc7 'D'`, `0xff`) are **not** handled
synchronously. Instead the dispatcher copies the 16-byte request
into a 10-slot ring, increments the slot index, and wakes the
`qc_app_task` loop. The ring base pointer is the literal value in
`DAT_0082bfcc`:

```c
// DAT_0082bfcc == 0x00209f54
memcpy((void *)(DAT_0082bfcc + 4 + slot * 0x10), param_1, 0x10);
slot = (slot + 1) % 10;
FUN_00827124(0, DAT_0082bfd0);   // signal qc_app_task
```

This is the same ring consumed by the Channel-A dispatcher
`FUN_0082d2dc`. The consumer is the main app task `qc_app_task`
(`FUN_0082724c`), whose loop waits on a message queue and then
 calls `FUN_0082d2dc()`:

```c
void FUN_0082724c(void) {
    // ... init ...
    do {
        do {
            msg = os_message_get(*(void **)(DAT_0082732c + 4), 0xffffffff);
        } while (msg == 0);
        FUN_0082d2dc();   // drains the 0x00209f54 ring
        FUN_0083304c();
        FUN_0082fc0c();
        // ...
    } while (true);
}
```

So `FUN_0082be64` does **not** have its own dedicated worker;
the deferred FEE7 frames are simply queued into the Channel-A
command ring and drained on the next `qc_app_task` tick. This is
how the watch avoids a single long 0xFEE7 frame from blocking the
BLE link while a CPU-heavy handler (e.g. `0x77 phoneSport` or
`0x43 readDetailSport`) runs.

#### Vendor NAK shape (`FUN_0082bcba`)

For an unknown opcode the dispatcher emits a 2-byte *vendor NAK*
frame:

```
byte 0: opcode | 0x80                (the high bit marks "error")
byte 1: 0xEE                        (vendor-NAK marker)
byte 2..14: 0
byte 15: additive checksum
```

The 0xEE marker is the same byte the 0xFEE7 GATT service
UUID uses (0x0000FEE7) — so a host that sees `[opcode|0x80, 0xEE]`
knows the response came from the vendor service (and not the
Channel-A 0xFF / 0xFE / 0x9F error variants).

#### Switch8 tables

Both tables use the shared `__ARM_common_switch8` helper at
`0x008405fc`. The helper reads a count byte immediately after the
`BL`, then a byte offset per case, and branches to
`target = (return_address + 2 * offset) & ~1`. Offsets are
**unsigned**.

##### Low-range table (`0x82c61c`) — opcodes `0x00..0x2a`

Count byte at `0x82c61c` is `0x27` (39 cases); cases
`0x27..0x2a` fall through to the default offset and are treated as
NAK.

| Opcode | Target / action | Notes |
|---|---|---|
| `0x00` | Vendor NAK (`0x82c74e`) | |
| `0x01` | Deferred (`0x82c662` → `FUN_0082be64`) | Channel-A `setTime` |
| `0x02` | `FUN_0082c4d4` | Camera / motor-mode request |
| `0x03` | `FUN_0082bc7e` | Battery response |
| `0x04` | `FUN_0082c432` | ANCS bind |
| `0x05` | Vendor NAK | |
| `0x06` | Deferred | Channel-A `dnd` |
| `0x07`–`0x09` | Vendor NAK | |
| `0x0a` | `FUN_0082b9c6` | Time-format read/set |
| `0x0b` | Vendor NAK | |
| `0x0c` | `FUN_0082c0de` | BP setting |
| `0x0d` | `FUN_00834252` + `FUN_0082c0a4` | Read BP records |
| `0x0e` | Deferred | Channel-A `bpReadConform` |
| `0x0f` | Vendor NAK | |
| `0x10` | `FUN_0082b9a8` | Vibration / display trigger |
| `0x11`–`0x13` | Vendor NAK | |
| `0x14` | Early return (`0x82c752`) | No-op |
| `0x15` | Deferred | Channel-A `readHeartRate` |
| `0x16` | `FUN_0082c164` | Heart-rate setting |
| `0x17` | Vendor NAK | |
| `0x18` | Deferred | Channel-A `realTimeHeartRate` |
| `0x19` | `FUN_0082c484` | Degree (°C/°F) switch |
| `0x1a`–`0x1d` | Vendor NAK | |
| `0x1e` | Deferred | |
| `0x1f`–`0x20` | Vendor NAK | |
| `0x21` | `FUN_0082bfd8` | Daily target setting |
| `0x22`–`0x24` | Vendor NAK | |
| `0x25`–`0x26` | Deferred | |
| `0x27`–`0x2a` | Default → Vendor NAK | |

The "deferred" entries in this range are the same opcodes handled
by the Channel-A deferred path (`FUN_0082be64`), so the FEE7
service can also be used to trigger them.

##### High-range table (`0x82c6e0`) — opcodes `0x97..0xa0`

Count byte at `0x82c6e0` is `0x0a` (10 cases); the default slot
also points to the vendor-NAK path.

| Opcode | Handler | Notes |
|---|---|---|
| `0x97` | `FUN_00827ba4` | No-op |
| `0x98` | `FUN_00827be6` | Sets `DAT_00827e8c[4] = 1`, sends `[0x98]` |
| `0x99` | `FUN_00827bea` | No-op |
| `0x9a` | `FUN_00827bec` | Sets `DAT_00827e8c[4] = 2`, sends `[0x9a]` |
| `0x9b` | `FUN_00827bf0` | Sends `[0x9b, state_byte]` where state byte is `0x77` if `DAT_00827e8c[4] != 2`, else `0x88` |
| `0x9c` | `FUN_00827c1e` | Sends `[0x9c,0,0,0x9c]`, stops a timer and powers off related subsystems |
| `0x9d` | Default → Vendor NAK | |
| `0x9e` | `FUN_00827cc8` | Conditional 10-byte copy from `DAT_00827e8c + 0x7a` or the literal `"H59MA_V1.0"` |
| `0x9f` | `FUN_00827b16` | No-op |
| `0xa0` | `FUN_00827d1a` | Multi-byte status frame built from `FUN_008289bc`, `FUN_00828fae`, `FUN_00832bd2`, `FUN_00837b90`/`FUN_008289a2`, and fields from `DAT_00827e8c` |

A host should treat both ranges as *reserved* unless it can match
a specific response shape from the watch.

#### Relationship to §8 opcode map

The opcode → handler map **above** supersedes the original §8
table (which only listed the *immediately-routed* opcodes).
The §8 table is now strictly a subset: the deferred opcodes
(`0x43`/`0x7a`/etc.) are still in the
opcodes-routed-to-`FUN_0082be64` bucket, and the
*handler-shorthand* in §8 is the per-deferred-frame handler
that `FUN_0082be64`'s worker eventually invokes.

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

Immediate / explicitly routed opcodes, including the non-default
entries decoded from the two `switch8` tables:

| Opcode | Handler | Notes |
|---|---|---|
| `0x02` | `FUN_0082c4d4` | Camera / motor-mode request |
| `0x03` | `FUN_0082bc7e` | Battery response (`[0x03, percent, charging]`) |
| `0x04` | `FUN_0082c432` | ANCS bind |
| `0x0a` | `FUN_0082b9c6` | Time-format read/set |
| `0x0c` | `FUN_0082c0de` | BP setting |
| `0x0d` | `FUN_00834252` + `FUN_0082c0a4` | Read BP records |
| `0x10` | `FUN_0082b9a8` | Vibration / display trigger |
| `0x14` | — | Explicit no-op (early `pop {r4,pc}`) |
| `0x16` | `FUN_0082c164` | Heart-rate setting |
| `0x19` | `FUN_0082c484` | Degree (°C/°F) switch |
| `0x21` | `FUN_0082bfd8` | Daily target setting |
| `0x36` | `FUN_0082c112` | Heart-rate related read/set — see §8.8 |
| `0x3c` | `FUN_0082c50e` | Returns fixed capability block `[0x3c,0,0x40,0xa0,0x20,...]` — see §8.12 |
| `0x3e` | `FUN_0082c550` | Lipids read/set (bit 7 of shared config byte) — see §8.15 |
| `0x48` `'H'` | `FUN_0082bf40` | Handshake response — sends 15-byte device-info block — see §8.2 |
| `0x50` `'P'` | inline | Calls `FUN_0082994c(0x14,0x10,1,0x19)` + `FUN_0082a5c8(8)` (alert/motor) |
| `0x51` `'Q'` | `FUN_0082c5b8` | "Find phone" / alert trigger; arms pattern when `payload[1]==1` — see §8.11 |
| `0x60` | `FUN_0082be90` | Status-field write (`DAT_0082bfd4 + 0x2c`) — see §8.16 |
| `0x61` `'a'` | `FUN_0082bee6` | Status response (battery / daily counters) — see §8.3 |
| `0x69` `'i'` | `FUN_0082c2f4` | Multi-step mode control (start/stop/cancel of a remote feature) — see §8.5 |
| `0x6a` `'j'` | `FUN_0082c1e2` | Continuation of `0x69` mode control |
| `0x90` | `FUN_00827ad2` | Echo `[0x90]` |
| `0x91` | `FUN_00827aee` | Echo `[0x91]` |
| `0x92` | `FUN_00827b14` | |
| `0x93` | `FUN_00827c4a` | |
| `0x94` | `FUN_00827b2e` | |
| `0x95` | `FUN_00827b54` | |
| `0x96` | `FUN_00827b7c` | Sends `[0x96,0,0,0x96,...]` and resets state — see §8.4 |
| `0x97` | `FUN_00827ba4` | No-op |
| `0x98` | `FUN_00827be6` | Sets state to `1`, sends `[0x98]` |
| `0x99` | `FUN_00827bea` | No-op |
| `0x9a` | `FUN_00827bec` | Sets state to `2`, sends `[0x9a]` |
| `0x9b` | `FUN_00827bf0` | Sends `[0x9b, state_byte]` |
| `0x9c` | `FUN_00827c1e` | Sends `[0x9c,0,0,0x9c]`, stops timer / power-off related |
| `0x9d` | — | Vendor NAK (default slot) |
| `0x9e` | `FUN_00827cc8` | Conditional 10-byte copy from `DAT_00827e8c + 0x7a` |
| `0x9f` | `FUN_00827b16` | No-op |
| `0xa0` | `FUN_00827d1a` | Multi-byte status frame builder |
| `0xbf` | `FUN_0082ba94` | |
| `0xc0` | `FUN_0082bb0c` | |
| `0xc1` | `FUN_008337fa` + `FUN_0082b938` | Sends a long/fragmented response |
| `0xc3` | `FUN_0082fe52` | Drives the OTA/DFU state machine (`param[2]==1` also calls `FUN_0082dfde`) |
| `0xc4` | `FUN_00830462` | No-op in firmware |
| `0xc5` | — | Sets `DAT_0082caec[3]` from `param[1]` |
| `0xc8` | — | Sets `DAT_0082caec[4]` from `param[1]` |
| `0xc9` | — | Sets `DAT_0082caec[5] = param[1]` |
| `0xcd` | `FUN_0082be12` | Byte-reverse echo of req[3..6] (link sanity test) — see §8.9 |
| `0xce` | `FUN_0082bcde` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) — see §8.10 |
| `0xfe` | `FUN_00844214` | Builds a vibration pattern from a duration argument — see §8.13 |

Opcodes `0x2b`, `0x37`, `0x38`, `0x3a`, `0x3b`, `0x43`, `0x72`,
`0x77`, `0x7a`, `0x7d`, `0x81`, `0xa1`, `0xc6`, `0xc7`, `0xff`
are routed to `FUN_0082be64` (deferred). Within the `0x00`–`0x2a`
`switch8` range, only `0x01`, `0x06`, `0x0e`, `0x15`, `0x18`,
`0x1e`, `0x25`, `0x26` are deferred; the rest are either immediate
thunks, the explicit no-op at `0x14`, or vendor NAK. Opcodes
`0x7b`, `0xb0`, `0xc2`, `0xcc`, `0xf0`, `0xf1` are explicit no-ops.
Unrecognized opcodes fall through to `FUN_0082bcba`.

### Take-away

The `0xFEE7` service carries a parallel 16-byte command channel that overlaps some Channel-A opcodes (e.g. `0x48`, `0x50`, `0x51`, `0x69`, `0x6a`, `0x3c`, `0x3e`) and adds vendor-specific commands (`0x90`–`0x9f`, `0xce`, `0xfe`). The OpenWatch host code should treat it as a second command path rather than a passive discovery UUID.

### 8.2 0x48 `'H'` handshake response (`FUN_0082bf40`)

The first frame the host sees on the `0xFEE7` service. Reads
the per-device info struct at `DAT_00831d94` and ships a
15-byte "device info" block. The struct base is the literal
`DAT_00831d94` — four sub-fields are read at offsets `+0x04`,
`+0x14`, `+0x1c`, and `+0x30`.

```c
void FUN_0082bf40() {
    u32 hw_ver   = FUN_00831b12();   // = *(u32*)(DAT_00831d94 + 0x04)
    u32 fw_ver   = FUN_00831cdc();   // = *(u32*)(DAT_00831d94 + 0x14)
    u32 batt_raw = FUN_00831ce2();   // returns FUN_0083dfba(*(u32*)(DAT_00831d94 + 0x1c), 100)
    u16 tail     = FUN_00831b1e();   // = *(u16*)(DAT_00831d94 + 0x30) — called twice
    ...
}
```

The 4 byte-fields read by the handlers are:

| Field | Struct offset | Likely meaning |
|---|---:|---|
| `hw_ver` (u32) | `DAT_00831d94 + 0x04` | hardware revision (e.g. `H59MA_V1.0`) |
| `fw_ver` (u32) | `DAT_00831d94 + 0x14` | firmware version (e.g. `1.00.14`) |
| `batt_raw` (u32) | `DAT_00831d94 + 0x1c` | raw battery counter, mod-100 → percent |
| `tail` (u16) | `DAT_00831d94 + 0x30` | charge / status bits |

#### Response layout (15 bytes + additive checksum)

The body is laid out as a 4 + 4 + 4 + 2 + 1 byte pattern that
packs the four getters in a specific interleaving:

```
byte  0: 0x48                         (cmd echo)
byte  1: hw_ver >> 16                (HW version byte C)
byte  2: hw_ver >>  8                (HW version byte B)
byte  3: hw_ver & 0xff               (HW version byte A)
byte  4: 0                           (pad)
byte  5: 0                           (pad)
byte  6: fw_ver >> 16                (FW version byte C)
byte  7: 0                           (pad)
byte  8: fw_ver & 0xff               (FW version byte A)
byte  9: fw_ver >>  8                (FW version byte B)
byte 10: batt_raw >> 16              (battery byte C — divmod 100 result)
byte 11: batt_raw >>  8              (battery byte B)
byte 12: batt_raw & 0xff             (battery byte A)
byte 13: tail & 0xff                 (low byte of status)
byte 14: tail >> 8                   (high byte of status)
byte 15: additive checksum           (per §3)
```

The interleaving of `hw_ver` (LE) and `fw_ver` (BE) is the same
quirk already documented in the `0x01 setTime` ack and the
`0x43 readDetailSport` headers — the firmware uses a
non-uniform byte order for the version fields, presumably
because the underlying C struct was packed in a vendor-
specific layout that the host SDK knows to read back with
the right shifts. The host should *not* try to read any of
the 4-byte version fields as plain little-endian; instead it
should read each as a 3-byte BCD-like value and ignore the
zero-pad byte.

#### Why the host's first call

* The `0x48` handler is one of the two opcodes (`0x43 'C'`,
  `0x48 'H'`) that the dispatcher *does not* reset the
  keep-alive timer for (see §8.1), so an idle host can poll
  the link with a continuous stream of `0x48` writes
  without ever bumping the watch's connection-timeout.
* The response always includes the live battery percent (via
  `FUN_0083dfba(_, 100)` mod 100), so a host that wants
  live battery data without subscribing to the `0x61 'a'`
  status push can simply poll `0x48`.

#### Pair with the 0x43 'C' read-byte

The two keep-alive-exempt opcodes are typically used as a
pair: `0x48` returns the 15-byte device-info block, `0x43`
returns a single byte (the `rxOpcode` — see the `Channel A`
read helper `FUN_0082b986`). A host that connects to the
`0xFEE7` service can issue `0x48` once to learn the device
info and then poll `0x43` at a low rate to verify the link
is still up.

### 8.3 0x61 `'a'` status response (`FUN_0082bee6`)

The vendor "live status" push endpoint. Carries a 4-byte
LE u32 status value (`DAT_0082bfd4 + 0x2C`) — the same
field that backs `0x48 'H'` battery percent — plus a
single-bit *idle* flag that lets the watch suppress the
status push when nothing has changed.

#### Behavior

```c
void FUN_0082bee6() {
    memset(rsp, 0, 0x10);
    rsp[0] = 0x61;
    if (FUN_0082762c() == 1 && FUN_0082d754() == 0) {
        // "idle" path — bytes 1..4 stay 0
        rsp[15] = FUN_0082b0c4(rsp, 0xf);
    } else {
        u32 v = *(u32*)(DAT_0082bfd4 + 0x2C);
        rsp[1] = v & 0xff;
        rsp[2] = (v >> 8) & 0xff;
        rsp[3] = (v >> 0x10) & 0xff;
        rsp[4] = (v >> 0x18) & 0xff;
        rsp[15] = FUN_0082b0c4(rsp, 0xf);
    }
    FUN_0082ebdc(rsp);
}
```

The two helper gates are:

| Helper | Reads | Returns |
|---|---|---|
| `FUN_0082762c` | `*(DAT_0082780c + 0x12)` | 1-byte state sentinel |
| `FUN_0082d754` | `*(DAT_0082db50 + 1)` | 1-byte state sentinel |

The "idle" path (`FUN_0082762c() == 1 && FUN_0082d754() == 0`)
returns an **all-zeros** status with the cmd byte alone —
the host can use this as a cheap heartbeat ("watch is alive
but nothing changed") instead of a full battery/counter
update. The "active" path returns the live u32.

#### Response layout

```
byte  0: 0x61                (cmd)
byte  1..4: u32 status (LE) from DAT_0082bfd4 + 0x2C
                on the active path, or 0/0/0/0 on the idle path
byte  5..14: 0
byte 15: additive checksum
```

The same `DAT_0082bfd4 + 0x2C` field is the source for the
`0x48 'H'` battery-percent helper (§8.2). The two responses
will therefore always agree on byte 1 (low byte of the
battery / daily-counter u32) — `0x61` is essentially the
"current snapshot" and `0x48` is the "device-info block
that includes the same snapshot".

#### Why the 1-byte-cmd-on-idle

The idle path is the cheapest possible response (16 bytes,
5 instructions, no memory reads beyond the two state
sentinels). A host that polls `0x61` aggressively can
treat repeated all-zero responses as "no change since last
poll" and avoid re-decoding the full status u32 each time.

#### State sentinels

`DAT_0082780c + 0x12` is the per-task state byte that
`FUN_008275d8` (the system reset routine used by `0xff` and
`0xc6`) clears at boot. `DAT_0082db50 + 1` is a similar
state byte in the deferred-command-ring worker (the same
ring that `0x77 phoneSport` and `0x43 readDetailSport` write
into). The handler checks both because the active state
depends on the *combined* condition: the task state is
"set up" AND the worker is "not busy". This means the
handler pushes a "live" status only when the watch is
*fully initialised* and the deferred ring is idle — a
deliberate gate to avoid pushing a status frame before the
producer side (`DAT_0082bfd4 + 0x2C`) has been populated.

#### Pair with `0x48 'H'`

| | `0x48 'H'` | `0x61 'a'` |
|---|---|---|
| Polling cost | full 15-byte device-info block | 5-byte u32 status |
| Idle response | (always returns full block) | all-zeros 1-byte-cmd ack |
| Live battery data | yes (FUN_0083dfba(_, 100) mod 100) | yes (same source as `0x48`) |
| Keep-alive exempt | yes (§8.1) | no — bumps `FUN_0082eebe` |

A host that wants *fast* battery updates can poll `0x61`
instead of `0x48` and skip the 11-byte header overhead, but
has to handle the idle-path "all zeros" response.

### 8.4 0x96 reset-state (`FUN_00827b7c`)

The vendor "reset to a clean state" command. Sends a
16-byte notify frame with **`0x96` at both byte 0 and byte
15** (no checksum — the byte-15 `0x96` is an *intentional
marker*, not a hash) and resets the per-feature state at
`DAT_00827e88`.

#### Behavior

```c
void FUN_00827b7c() {
    rsp[0] = 0x96;
    rsp[12] = 0x96;                          // bytes 1..11 + 13..14 = 0
    FUN_0082ebdc(&rsp);
    state = DAT_00827e88;
    state[1] = 0;                            // clear flag byte
    *state = 4;                              // set state byte = 4
    FUN_00827b1a();                          // drain/reset helper
}
```

The handler is one of the few Channel-A / 0xFEE7 opcodes
that **does not call `FUN_0082b0c4`** to compute an
additive checksum. Instead, it sets byte 15 to a literal
`0x96`. The host can detect a `0x96` reset by:
1. Looking for byte 0 = byte 15 = `0x96`.
2. Treating the frame as a "reset happened" signal rather
   than a normal response.

#### Persistent state (`DAT_00827e88`, 2 bytes)

| Off | Field | Notes |
|---:|---|---|
| 0 | `state_machine_state` | set to `4` on reset |
| 1 | `feature_flag` | cleared on reset |

These two bytes form the **head** of the larger state
struct at `DAT_00827e88` — the helper `FUN_00827b1a` then
drains 1000 bytes starting at `DAT_00827e88 + 10` (the rest
of the struct).

#### `FUN_00827b1a` — reset helper

```c
void FUN_00827b1a() {
    FUN_00829c24(DAT_00827e88 + 10, DAT_00827e90, 1000, 1);
}
```

A single call to `FUN_00829c24` with a 1000-byte copy /
queue-drain parameter and a `1` flag (likely "drain"
vs "fill"). `DAT_00827e90` is presumably the destination
buffer for the cleared state (or a queue head for the
drained work items).

#### Response layout

```
byte  0: 0x96                (cmd)
byte  1..11: 0
byte 12..14: 0
byte 15: 0x96                (intentional marker — NOT a checksum)
```

The `0x96` at byte 15 is the host's "I just reset" signal.
The lack of a checksum means a host that tries to verify
the additive sum of bytes 1..14 will compute `0x00` (all
zeros) and *not* match the byte-15 `0x96`. The proper
verification is `byte 0 == 0x96 && byte 15 == 0x96` (a
self-describing marker pair), not the additive checksum
that the §3 "Common response path" usually stamps in.

#### Why no additive checksum

The handler bypasses `FUN_0082b0c4` because the byte-15
slot is **already used as the second `0x96` marker**. This
is the only handler in the table that does so. The host
SDK that consumes `0x96` should special-case this opcode
to read bytes 0 and 15 as marker bits rather than the
usual `cmd + checksum` pair.

#### When a host sends `0x96`

A host typically sends `0x96` to recover from a desync —
the watch state has drifted (the producer side at
`DAT_00827e88` is in an unexpected mode) and the host
wants the firmware to reinitialise the feature from
scratch. The `0x96` ack tells the host "I have reset,
the next request will be against a fresh state". This is
analogous to the `0xff 'fff'` Channel-A factory reset
(§3.8) and the `0xc6 0x6C 'l'` 0xFEE7 reboot (§3.14), but
narrower in scope — only the `DAT_00827e88` feature is
reset, not the whole system.

#### Pair with `0xC9` config-byte write

`DAT_00827e88[5]` is writable via `0xC9` (§8.1) — `0xC9`
sets `DAT_0082caec[5] = req[1]`, which the dispatcher then
mirrors into the feature state. The combination `0x96`
reset followed by `0xC9` set is the documented host pattern
for switching between "feature on" and "feature off"
modes without a full BLE reboot.

### 8.5 0x69 `'i'` mode control (`FUN_0082c2f4`)

The most stateful handler in the 0xFEE7 dispatcher. Drives
a multi-step "start / stop / cancel / refresh" sequence
over a per-feature state struct at `DAT_0082c578`. The
handler implements both a **HR-busy gate** (refuse to act
if the HR step counter is running) and a **500 ms tick**
that the mode-control state machine relies on.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x69` | cmd (consumed by dispatcher) |
| 1 | `mode` | see dispatch table below |
| 2..3 | `param` (u16 LE) | per-mode parameter (interval, duration, etc.); clamped to `>= 10` |
| 4..14 | unused | — |

#### HR-busy gate

The very first thing the handler does is call
`FUN_00828af4()` (the same HR step-counter check used by
`0x08 0x01` start-find in §3.15). If the counter is
*running*, the handler short-circuits:

```c
if (FUN_00828af4() != 0) {
    rsp[0..1] = (0x69, req[1]);
    rsp[2]    = 1;                    // "busy" flag
    rsp[15]   = additive checksum;
    send rsp;
    return;
}
```

The host treats `rsp[2] == 1` as "request was ignored because
HR is currently recording a sport session — retry after
`0x77 0x02` finishes". This is the same gating strategy used
by `0x77 0x01` (§3.16).

#### Mode dispatch (when HR not busy)

The handler writes `req[1]` to `state[7]` (mode) and
`req[2]` to `state[8]` (sub), then dispatches on `(mode,
sub)`:

| Mode | Sub | Action |
|---:|---:|---|
| `0x06` | `0x01` | **Start**: zero `state[0xC..0xD]`, call `FUN_0083371e(1)` (HR continuous start), cancel timer at `state[0x10]`, arm 500 ms timer |
| `0x06` | `0x02` | **Cancel**: cancel timer |
| `0x06` | `0x03` | **Refresh**: cancel + re-arm 500 ms timer |
| `0x06` | `0x04` | **Stop HR**: call `FUN_00833704(1)` (HR stop), zero `state[0xC..0xD]` |
| `0x06` | other | (no action — go to send) |
| other | any | **Generic mode start**: zero `state[0xC..0xD]` and `state[2]`, cancel + re-arm 500 ms timer, then dispatch on `state[7]` (just-stored mode) for the per-mode start action (see "Per-mode start dispatch" below) |

#### Per-mode start dispatch (mode ≠ 0x06)

When the mode is not `0x06`, the handler reads back
`state[7]` (the mode it just stored) and dispatches:

| `state[7]` | Action |
|---:|---|
| `0x03` | `FUN_0083371e(0x20)` (HR mode `0x20`) |
| `0x09` | `FUN_00834862()` + `FUN_0083371e(0x400)` |
| `0x0B` (11) | `FUN_0083371e(0x1000)` + `FUN_0082ad02()` (some calibration / step-counter init) |
| `0x0C` (12) | `FUN_0083475a()` + `FUN_0082ad02()` + `FUN_0083454c()` + `FUN_0083371e(DAT_0082c57c)` (data-driven mode param) |
| `0x0D` (13) | `FUN_0083371e(1)` |
| `0x0E` (14) | `FUN_0083371e(0x20)` |
| other | (fallback — `FUN_0083371e(1)`) |

For all non-fallback modes the handler then:
1. Reads `req[2..3]` as a u16 `param`
2. Stores `param` into `state[0xA]` (inter-mode duration or
   interval)
3. Clamps `param` to `>= 10` (the doc-table explains this
   matches the watch's 10 ms timer granularity)

#### Persistent state (`DAT_0082c578`)

| Off | Field | Notes |
|---:|---|---|
| 2 | `step_counter_flag` | zeroed at every start path |
| 7 | `current_mode` | the mode byte just stored from `req[1]` |
| 8 | `current_sub` | the sub byte from `req[2]` |
| 0xA..0xB | `param_u16` | the clamped u16 parameter (only set in the generic-mode start) |
| 0xC..0xD | `param_zero` | zeroed on `0x06` start and `0x06 0x04` stop |
| 0x10+ | `timer_state` | the 500 ms tick used by both branches |

`DAT_0082c57c` (the +4 sibling) holds the "data-driven"
mode param consumed by the `0x0C` mode. Likely a config
table the producer populates via `0xC5` / `0xC8` / `0xC9`.

#### Why a 500 ms tick

The 500 ms timer at `state[0x10]` is the *mode-control tick*
— it advances the state machine for long-running modes
(those that take more than the single 16-byte frame to
complete). The host does not need to poll the timer; the
watch fires any follow-up data on the 0xFEE7 ring when the
tick expires. This is the same pattern as `0x77 phoneSport`
(§3.16) and `0x08 findDevice` (§3.15) — both use a
~1-second or ~500 ms timer to advance their state machines.

#### Response layout

For the HR-busy path:
```
byte  0: 0x69                (cmd)
byte  1: req[1]              (echo of mode)
byte  2: 0x01                ("busy" flag — request was ignored)
byte  3..14: 0
byte 15: additive checksum
```

For the "not busy" path:
```
byte  0: 0x69                (cmd)
byte  1: state[7]             (echo of the mode just stored)
byte  2: 0x00                (always 0 in the not-busy path)
byte  3..14: 0
byte 15: additive checksum
```

The host decodes `byte 2` as a "request status" flag:
`0` = accepted, `1` = refused (HR busy). The mode echo in
`byte 1` confirms which mode the request landed on
(useful when the host's `req[1]` was outside the table —
the handler clamps to `0x06` and the echo reflects that).

#### Pair with `0x6a 'j'`

`0x6a 'j'` (handled by `FUN_0082c1e2`) is the *continuation*
of `0x69 'i'` — when the 500 ms timer fires, it pops the
mode's continuation state and dispatches the next step.
The host should treat `0x69` + `0x6a` as a single
multi-frame transaction: `0x69` *starts* the mode,
`0x6a` *advances* it. The split is necessary because the
0xFEE7 16-byte frame cannot carry the full per-mode state;
`0x6a` re-reads `DAT_0082c578` and pushes the next-step
data on the notify ring.

### 8.6 0x90 `'.'` self-marker echo (`FUN_00827ad2`)

The smallest 0xFEE7 echo handler (27 bytes). Sends a
16-byte notify frame with `0x90` at both byte 0 AND byte
15 — a **self-marker pattern** identical in shape to the
`0x96` reset-state response (§8.4). The handler does *not*
compute an additive checksum; the byte-15 slot is reserved
for the second `0x90` marker.

#### Behavior

```c
void FUN_00827ad2() {
    rsp[0]  = 0x90;            // cmd
    rsp[12] = 0x90;            // byte 12 (high byte of u32 at offset 12)
    rsp[15] = 0;               // (byte 15 of u32 at offset 12 → 0x90 from
                               //  the high byte; see note below)
    FUN_0082ebdc(rsp);
}
```

The handler writes:
- `local_18 = 0x90` → bytes 0..3 of the frame are `[0x90, 0, 0, 0]`.
- `local_c = 0x90000000` → bytes 12..15 of the frame are
  `[0x00, 0x00, 0x00, 0x90]` (little-endian high-byte at offset 15).
- Bytes 4..11 are 0 (from the `local_14 = local_10 = 0`
  initialisations).

So the wire frame is:

```
byte  0: 0x90        (cmd)
byte  1..11: 0
byte 12..14: 0
byte 15: 0x90        (intentional marker — NOT a checksum)
```

The host verifies by `byte 0 == 0x90 && byte 15 == 0x90`,
**not** by additive checksum. This is the second handler
in the table (after `0x96` §8.4) to use the byte-15 slot
as a marker rather than a hash.

#### Why no additive checksum

Same reason as `0x96 reset-state` (§8.4): the byte-15 slot
is *already used* as the second `0x90` marker. The host SDK
that consumes `0x90` should special-case this opcode to
read bytes 0 and 15 as marker bits rather than the usual
`cmd + checksum` pair.

#### Pair with `0x91` (proper echo)

The adjacent `0x91` handler (`FUN_00827aee`) is the
"normal" version of the same idea — a simple echo of the
opcode with a *real* additive checksum:

```c
void FUN_00827aee() {
    rsp[0]  = 0x91;
    rsp[15] = FUN_0082b0c4(rsp, 0xf);   // additive sum of bytes 0..14
    FUN_0082ebdc(rsp);
}
```

So `0x90` (self-marker) and `0x91` (checksum-echo) are
*deliberately different*: `0x90` lets the host cheaply
detect "watch is alive" without paying for a checksum
computation, while `0x91` is the host SDK's primary
echo command that round-trips through the standard
§3 "Common response path" checksum.

#### Adjacent `0x92` is a no-op

For completeness, `0x92` (`FUN_00827b14`) is an empty
function (decompiles to `return;`). The handler is wired
into the `0xFEE7` dispatcher but does nothing — the
opcode is reserved for a future vendor-specific feature
that v14 does not implement. A host sending `0x92` will
*not* receive any response (the dispatcher routes it but
the handler is empty).

### 8.7 0x6a `'j'` mode-control continuation (`FUN_0082c1e2`)

The second half of the `0x69 'i'` / `0x6a 'j'` multi-step
transaction (§8.5). The dispatcher (§8.1) routes both
opcodes to `FUN_0082be64` (the deferred ring), but only
`0x69` starts a new mode; `0x6a` *advances* the mode already
in progress by re-reading `DAT_0082c578` and dispatching
on the mode to call the appropriate sensor-read helper.

The handler also enforces a **mode-mismatch guard**: if
`req[1]` does not match `state[7]` (the mode stored by the
matching `0x69 'i'`), the handler returns immediately. This
prevents a stale `0x6a` request from continuing the wrong
mode if the host lost track of the protocol state.

#### Pre-dispatch: gate and bucket logic

```c
if (req[1] != state[7]) return;          // mode-mismatch guard

if ((cVar1 == '\r') || (cVar1 == '\x0e')) {
    FUN_00833704(DAT_0082c580);          // stop HR with stored mode
    func_0x000136bc(state + 0x10);       // cancel 500 ms timer
    state[7] = 1;                        // reset to mode 1 (idle)
} else if (*(u16*)(state + 0xC) < 0x3C) {
    // 0xC is the "frame count" that 0x69 advanced;
    // if it's < 60 (the typical full-data threshold),
    // pick the matching stop parameter and bail early.
    FUN_00833704(<stop_param>);
    func_0x000136bc(state + 0x10);
    if (*(u16*)(state + 0xC) < 0x32) return;
}
```

The two pre-dispatch buckets handle:

* **Modes `0x0D` (13) and `0x0E` (14)** — special-case
  *stop* paths: stop HR using `DAT_0082c580` (the mode
  parameter stored by `0x69`), cancel the 500 ms tick, and
  set `state[7] = 1` (the "idle" sentinel).
* **Modes with `state[0xC] < 60`** — partial-data paths:
  the `0xC` field is the "frame count" that `0x69`
  accumulated; if it's under 60, the handler picks the
  matching stop parameter and *bails before re-entering
  the per-mode start dispatch*.

If neither bucket fires (mode is not `0x0D/0x0E` AND
`state[0xC] >= 60`), the handler falls through to the
full per-mode start dispatch.

#### Per-mode start dispatch

| Mode | Action | Sensor read |
|---:|---|---|
| `0x03` | `FUN_00833704(0x20)` | `FUN_00833a50()` |
| `0x09` | `FUN_00833704(0x400)` | `FUN_0083485c()` |
| `0x0B` | `FUN_00833704(0x1000)` | `FUN_0082acf6()` |
| `0x0C` | `FUN_00833704(DAT_0082c57c)` (data-driven) | `FUN_00837ade()` + 3 more reads (see below) |
| other | `FUN_00833704(1)` | `FUN_00837ade()` |

The `FUN_00833704(<param>)` calls are the same HR-driver
"stop with mode parameter" wrappers used in `0x69 'i'` and
`0x1e realTimeHeartRate`. The `uVar4 = <sensor_read>()` is
the **1-byte result** that ends up in `byte 2` of the
response.

#### Special case: mode `0x0C` (12)

For mode `0x0C` the handler reads **5 sensor values** and
packs them into the response frame:

```c
uVar4 = FUN_00837ade();           // 1st
local_28 = CONCAT13(uVar4, <0>);  // byte 3 = uVar4
uVar4 = FUN_008346e4();           // 2nd
local_24 = CONCAT31(<hi3>, uVar4); // byte 0 of local_24 = uVar4
uVar4 = FUN_00834556();           // 3rd
local_24._0_2_ = CONCAT11(uVar4, <old_byte0>); // byte 0 = uVar4
uVar4 = FUN_0082acf6();           // 4th
local_20 = CONCAT31(<hi3>, uVar4); // byte 0 of local_20 = uVar4
FUN_00834092(local_28._3_1_, &local_20 + 1, &local_20 + 2);
                                   // copy byte 3 of local_28 into bytes 1..2 of local_20
```

The final `local_28` / `local_24` / `local_20` block holds
the 5 sensor bytes scattered across the response bytes 2..4
and bytes 0..1 of `local_20` (which becomes bytes 8..9 of
the final response). The host must read these bytes in the
right order to reconstruct the sensor trace.

#### Response layout

The handler writes the cmd and echo **last**:

```c
local_28 = (uint)CONCAT11(local_28._3_1_, uVar4) << 0x10;  // pack sensor data
LAB_0082c256:
local_28._0_2_ = CONCAT11(req[1], 0x6a);                    // overwrite bytes 0..1
rsp[15] = FUN_0082b0c4(local_28, 0xf);                    // additive checksum
FUN_0082ebdc(local_28);
```

So the final 16-byte response is:

```
byte  0: req[1]              (echo of mode)
byte  1: 0x6a                (cmd — note: byte 0/1 reversed vs §3 convention)
byte  2: uVar4 (sensor read) | bytes 2..4 packed sensor trace for 0x0C
byte  3..14: 0 | packed sensor trace for 0x0C
byte 15: additive checksum
```

The **byte 0 / byte 1 reversal** is deliberate: the
handler builds bytes 0..1 *last* so the cmd is the last
byte written, but the order in `CONCAT11(req[1], 0x6a)`
puts `req[1]` at byte 0 and `0x6a` at byte 1. The host
SDK that consumes `0x6a` must read the cmd from **byte 1**
and the echo from **byte 0** — *not* the usual `byte 0 =
cmd` convention used by §3 handlers. This same quirk
appears in `0x69 'i'` (§8.5) and is the only place in the
table where the response shape diverges from the §3
"Common response path".

#### Why the byte 0/1 reversal

The §3 "Common response path" handlers all set `byte 0 =
cmd` first via `local_18 = CONCAT11(0, cmd)` (low byte 0,
high byte cmd). The `0x69 'i'` / `0x6a 'j'` pair instead
set byte 0 = `req[1]` (echo) and byte 1 = cmd, because
the dispatcher (§8.1) routes both opcodes through the
**deferred ring** (`FUN_0082be64`) and the worker pops
the stored frame with the cmd byte at position 1 (so the
host's echo of `req[1]` is the *first* byte the worker
sees). This is a vestige of the deferred-ring layout; the
non-deferred `0x90` self-marker (§8.6) and `0x91` echo
both follow the §3 convention.

### 8.8 0x36 heart-rate related read/set (`FUN_0082c112`)

The 0xFEE7-side HR-related flag — structurally a *clone*
of the Channel-A `0x38 pressure` (§3.17) and `0x2c SpO2`
(§3.10) handlers. Stores a 1-bit on/off value as **bit 2**
of the same shared `DAT_008277f0 + 0x2D` config byte that
the other 1-bit features live in.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_20[2] = FUN_0082768e()` — read bit 2 of `*(DAT_008277f0 + 0x2D)`, masked `& 7 >> 2` yields `0` or `1` | `FUN_0082768e` |
| other (write) | `FUN_0082769a(req[2] == 1)` — if `req[2] == 1`, set bit 2; else clear it. Response **echoes** `req[2]` | `FUN_0082769a` |

The mask `& 7` and the `>> 2` shift confirm that only
bits 2..3 of the byte are owned by this handler; the other
6 bits belong to other features.

#### Persistent state (1 bit)

| Bit | Field | Owner |
|---:|---|---|
| 0 | (other) | — |
| 1 | `spo2_enabled` | `0x2c SpO2` (§3.10) |
| 2 | `hr_related` | **`0x36` (this handler)** |
| 3 | `pressure_enabled` | `0x38 pressure` (§3.17) |
| 4 | (other) | — |
| 5 | `sugar` | `0x3a sub 0x03` (§3.22) |
| 6 | (other) | — |
| 7 | `lipids` | `0x3a sub 0x04` (§3.22) |

This completes the 4-bit feature map at `DAT_008277f0 +
0x2D`. The 0x36 bit at position 2 is the "HR-related" flag
that pairs with the larger HR opcodes `0x15 readHeartRate`
(§3.12) and `0x1e realTimeHeartRate` (§3.13) on the
Channel-A side.

#### Response layout

```
byte  0: 0x36                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: feature value      (0/1 for read; echoed req[2] for write)
byte  3..14: 0
byte 15: additive checksum
```

Identical to `0x38 pressure` (§3.17) and `0x2c SpO2`
(§3.10). The shared `DAT_008277f0 + 0x2D` byte is the
"per-feature enable bitmap" that the watch reads whenever
it consults which sensors are active.

#### Why a separate 0xFEE7 opcode

`0x36` is the **0xFEE7 vendor variant** of `0x15
readHeartRate` (§3.12). The two are functionally equivalent
(turn the HR sensor on or off) but the host SDK that
consumes the 0xFEE7 service uses `0x36` for the lightweight
1-bit on/off control, while the Channel-A `0x15` is the
"full read" command that returns a 292-byte multi-frame
record (§3.12). A host that wants *fast* HR toggling can
use `0x36`; a host that wants *full HR data* must use the
Channel-A `0x15` / `0x1e` opcodes.

#### Pair with `0xC5/0xC8/0xC9` config-byte writes

§8.1 documents that `0xC5` writes `DAT_0082caec[3]`,
`0xC8` writes `DAT_0082caec[4]`, and `0xC9` writes
`DAT_0082caec[5] = req[1]`. None of these touch the
`DAT_008277f0 + 0x2D` byte directly — the 0xFEE7
"service-suspended" gate is *orthogonal* to the
per-feature enable bitmap. The host can toggle `0x36` to
disable the HR sensor without affecting the `0xC5/0xC8/0xC9`
flags, and vice-versa.

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

### 8.9 0xcd byte-reverse echo / link-sanity test (`FUN_0082be12`)

A vendor-service **byte-order sanity check**. When the host
sends `0xcd 0x01 LEN B3 B4 B5 B6`, the watch responds with
`0xcd B6 B5 B4 B3 0 0 ... LEN bytes total`. The handler
**reverses the byte order of `req[3..6]`** in the response,
so a host can verify its byte-order interpretation matches
the firmware's by sending a known 4-byte value and checking
the response.

#### Behavior

```c
void FUN_0082be12(int param_1) {
    rsp[0] = 0xcd;
    if (req[1] == 1) {
        uint8_t len = min(req[2], 0x0E);    // clamp to 14
        uint32_t packed =
              (req[3] << 24) |
              (req[4] << 16) |
              (req[5] <<  8) |
              (req[6]      );   // req[3..6] in big-endian order
        memcpy(rsp + 1, &packed, len);    // memcpy the low `len` bytes
    }
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The disassembly uses the explicit `rev16` ARM instruction
to byte-swap `(req[3] << 8) | req[4]` back to
`(req[4] << 8) | req[3]` after a misleading initial
`((req[4] << 8) | req[3])` build — the net effect is
**big-endian pack** of `req[3..6]` into a 32-bit register,
which the subsequent `memcpy` reads in little-endian order
to produce the **byte-reverse echo**.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xcd` | cmd (consumed by dispatcher) |
| 1 | `sub` | must be `0x01` — other values skip the echo and return an all-zeros response |
| 2 | `len` | echo length; clamped to 14 (4-byte packed source only carries 4 bytes — values > 4 read uninitialised stack) |
| 3..6 | `payload` | 4-byte payload; echoed in reverse byte order in the response |

#### Response layout

```
byte  0: 0xCD                (cmd)
byte  1: req[6]              (echo of byte 6 of payload)
byte  2: req[5]              (echo of byte 5 of payload)
byte  3: req[4]              (echo of byte 4 of payload)
byte  4: req[3]              (echo of byte 3 of payload)
byte  5..14: 0 / uninit     (clamp `req[2]` to 4 to be safe)
byte 15: additive checksum
```

The host should send `req[2] == 4` to avoid reading
uninitialised stack bytes into bytes 5..14.

#### `sub != 0x01` behavior

When `req[1] != 1`, the handler skips the echo entirely
and sends an **all-zeros** response `[0xCD, 0, ..., 0, cksum]`.
This is a cheap way for the host to confirm the watch is
alive without committing a known payload to the echo path.

#### Why a byte-reverse echo

This is the **classic ARM-Thumb byte-order probe**. ARM
instructions are little-endian-native, but Bluetooth L2CAP
channels can carry data in either byte order depending on
the host's stack. The `rev16` instruction + the
big-endian pack give the host a way to verify the wire
byte order without depending on its own internal byte
order — if the watch returns `B6 B5 B4 B3`, the host knows
its wire-side byte order matches the firmware's.

A typical host-side check:

```dart
final probe = Uint8List.fromList([0xCD, 0x01, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]);
await transport.send(probe);
final reply = await transport.receive();
assert(reply[1] == 0xDD);
assert(reply[2] == 0xCC);
assert(reply[3] == 0xBB);
assert(reply[4] == 0xAA);  // byte-reversed
```

If any of these asserts fail, the host should fall back to
swapping its outgoing payload before retrying.

#### Why `rev16` and not `bswap`

`rev16` reverses byte order within a 16-bit halfword; the
`lsl #16` that follows widens it to a 32-bit value with
the original bytes in the *high* halfword. This avoids the
need for a full 32-bit `rev` instruction and lets the
subsequent ORs add bytes 5 and 6 in the *low* halfword
without disturbing the high half. The end result is the
same as `rev` + `lsl #0` would give, but `rev16` is a
16-bit Thumb instruction and uses one fewer cycle than
the 32-bit `rev`.

### 8.10 0xce factory/test sub-commands (`FUN_0082bcde`)

The vendor-test entry point. Dispatches on five
*non-sequential* sub-cmd bytes — `0x01`, `0x02`, `' '`
(0x20), `'!'` (0x21), `'"'` (0x22) — to a mix of generic
config writers and vendor-specific self-test loops.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xce` | cmd (consumed by dispatcher) |
| 1 | `sub` | selects the sub-command (see table below) |
| 2 | `param0` (u8) | passed as first arg to FUN_008336e8/0083361c/00838fae/008381a2/008381c0 |
| 3 | `param1` (char) | passed as second arg to FUN_008336e8/0083361c |
| 4 | `len` (u8) | copied into `local_18` — the response-copy length |
| 5..14 | `data[10]` | copied into the `local_28` buffer |

#### Sub-cmd dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` | `FUN_008336e8(local_1c, cVar2, &local_28, local_18)` — write 10-byte config chunk | `FUN_008336e8` |
| `0x02` | `FUN_0083361c(local_1c, cVar2, &local_28, local_18)` — read 10-byte config chunk | `FUN_0083361c` |
| `' '` (0x20) | **Hardware self-test loop** (see below) | `FUN_00838bc0` + 9×`(*puVar3)()` + `FUN_00833400` |
| `'!'` (0x21) | **Bit-test** — `local_28 = ((*(uint*)(DAT_0082bfc8 + 0x10) & FUN_00838fae(local_1c)) != 0); local_18 = 1` | `FUN_00838fae` |
| `'"'` (0x22) | `FUN_008381a2(local_1c, 0x5A); FUN_008381c0(local_1c, 0, 1, cVar2 == 0)` | `FUN_008381a2` + `FUN_008381c0` |
| other | falls through to response copy only | — |

#### `' '` (0x20) hardware self-test

```c
FUN_00838bc0(DAT_0082bfc0);              // reset vendor test context
puVar3 = DAT_0082bfc4;                  // function pointer table
for (i = 0; i < 9; i++) {
    FUN_008381c0(0x14, 0, 1);          // vendor write 1
    (*puVar3)(1);                        // call test routine
    FUN_008381c0(0x14, 0, 1);          // vendor write 1 again
    (*puVar3)(1);                        // call test routine
}
FUN_008381c0(0x15, 0, 1);              // vendor write 2
(*puVar3)(1);                            // call test routine
FUN_008381c0(0x15, 0, 1);              // vendor write 2 again
(*puVar3)(1);                            // call test routine
FUN_00833400();                          // finalise test
```

The `' '` self-test runs **20 vendor calls** in a tight loop
(9 iterations × 2 calls each = 18 + 2 trailing calls = 20).
Each pair is "write-vendor-reg `0x14` then call the
test-routine; do it again". The trailing 2 calls use
vendor-reg `0x15` (a different control register) and call
the same test routine. The `FUN_00838bc0(DAT_0082bfc0)`
is a "reset vendor test context" prep, and `FUN_00833400()`
is a "finalise" / "log result" tail call.

The `(*puVar3)()` indirection through `DAT_0082bfc4`
(function-pointer table) means the actual test routine is
**not** in the firmware body — it's loaded from a vendor-
specific table that lives elsewhere in the image (likely a
patch table the OEM ships for factory testing). A host that
sends `' '` without that vendor table populated will jump
to whatever pointer is at `DAT_0082bfc4` at runtime; if
the table is null, this is a *crash*.

This makes the `' '` sub-cmd a **factory-floor-only command**:
the OEM populates `DAT_0082bfc4` with a vendor-supplied
test routine before flashing the production firmware, and
only factory-floor equipment is expected to send it. A
normal OpenWatch host should never send `' '`.

#### `'!'` (0x21) bit-test

```c
uVar5 = FUN_00838fae(local_1c);          // read a vendor status u32
local_28 = ((*(uint*)(DAT_0082bfc8 + 0x10) & uVar5) != 0);
local_18 = 1;
```

A **mask + bit-test**: the handler reads a 4-byte vendor
status register via `FUN_00838fae(local_1c)`, AND-masks it
against the value stored at `DAT_0082bfc8 + 0x10`, and
writes a single byte (`0x00` or `0x01`) into `local_28[0]`
based on whether the masked result is non-zero. `local_18`
is set to `1` so the response carries exactly one byte of
result. The host supplies `local_1c` (the status index) and
reads back a single boolean.

#### `'"'` (0x22) generic vendor write + check

```c
FUN_008381a2(local_1c, 0x5A);            // vendor write with mode 0x5A
FUN_008381c0(local_1c, 0, 1, cVar2 == 0); // vendor write with check
```

Two vendor helper calls. `FUN_008381a2` writes the
"diagnostic mode" value `0x5A` to the vendor register
indexed by `local_1c`. `FUN_008381c0` then writes a
"check" value (the second arg `0`, third arg `1`, fourth
arg is `cVar2 == '\0'`) to the same register. The
`cVar2 == '\0'` flag is the "fail-on-error" toggle: the
host's `req[3]` selects whether the check is allowed to
fail.

#### Response layout

After the dispatch, the handler copies `local_18` bytes
from `local_28` into the response:

```c
memcpy(rsp + 1, &local_28, local_18);
rsp[15] = FUN_0082b0c4(rsp, 0xf);
FUN_0082ebdc(rsp);
```

So the response is:

```
byte  0: 0xCE                         (cmd)
byte  1..N: <local_18 bytes of local_28> (N = local_18 = req[4])
byte  N+1..14: 0
byte 15: additive checksum
```

The `local_18` value (originally `req[4]`, but rewritten
for the `'!'` sub-cmd to `1`) controls how many payload
bytes the response carries:
* For `'0x01'` / `'0x02'` config R/W: `local_18 == req[4]`
  (the requested chunk length).
* For `' '` self-test: `local_18` is unchanged from `req[4]`,
  but `local_28` is all zeros (the helper doesn't write
  anything back). The response carries `req[4]` zero bytes.
* For `'!'` bit-test: `local_18 == 1` (the boolean result).
* For `'"'` generic: `local_18` is unchanged from `req[4]`,
  but `local_28` is all zeros.

#### Why the ASCII sub-cmd bytes

The use of `' '`, `'!'`, `'"'` (ASCII 0x20 / 0x21 / 0x22) as
sub-cmd selectors is a *vendor convention*: it lets a human
operator type the literal sub-cmd on a serial-terminal
interface and have the firmware do the right thing. The
firmware treats the sub-cmd byte as opaque data and never
parses the ASCII semantics — `0x20` and `0x21` are just
two more values in the dispatch switch.

#### Pair with `0xA1` factory/test mode (Channel-A)

`0xa1` is the Channel-A *user-facing* factory-test mode
(§3.x). It dispatches on sub-cmd bytes `0x01..0x06` for
HR step-counter operations. `0xce` is the 0xFEE7 vendor
*factory-floor* test mode that talks to the OEM's vendor
test tables (`DAT_0082bfc0`/`bfc4`/`bfc8`). They are
*orthogonal* features: `0xa1` is reachable by any host;
`0xce` is reachable only when the OEM has populated the
vendor tables.

### 8.11 0x51 `'Q'` find-phone / long alert (`FUN_0082c5b8`)

The "find phone" / longer alert trigger. Mirrors `0x50 'P'`
(§8.1) with different vendor-alert parameters — together
they are the two fire-alert commands on the 0xFEE7 service.

#### Behavior

```c
void FUN_0082c5b8(int param_1) {
    rsp[0] = 0x51;
    if (req[1] == 0x01) {
        FUN_0082994c(100, 0x10, 2, 8);   // vendor alert: mode 100, count 2, repeat 8
        FUN_0082a5c8(9);                  // motor pattern #9
    }
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The handler fires a vendor alert pattern when `req[1] == 1`
and always sends the ack frame. Non-`0x01` sub-cmd values
are silently ignored — the ack ships with an empty body
(`[0x51, 0, 0, ..., 0, cksum]`).

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x51` | cmd (consumed by dispatcher) |
| 1 | `sub` | must be `0x01` to trigger; other values are no-ops |

Bytes 2..14 are ignored.

#### Response layout

```
byte  0: 0x51                (cmd)
byte  1..14: 0
byte 15: additive checksum
```

The body is always empty — the handler does not return any
"trigger accepted" detail, just the cmd-and-checksum ack.
This is identical to `0x50 'P'` (§8.1).

#### `0x50 'P'` vs `0x51 'Q'` comparison

| Param | `0x50 'P'` (inline) | `0x51 'Q'` (§8.11) |
|---|---|---|
| `FUN_0082994c` mode | `0x14` | `100` (`0x64`) |
| `FUN_0082994c` param | `0x10` | `0x10` |
| `FUN_0082994c` count | `1` | `2` |
| `FUN_0082994c` repeat | `0x19` (25) | `8` |
| `FUN_0082a5c8` pattern | `8` | `9` |

The two opcodes are the *short* alert (`0x50`: single
rep, 25 repeats) and the *long* alert (`0x51`: two reps,
8 repeats). A host that wants to beep the watch briefly
should send `0x50`; a host that wants to play a longer
"find my watch" sequence should send `0x51`. The motor
pattern numbers (8 vs 9) are presumably the vendor's
naming for the corresponding alert tunes.

#### Why two opcodes for the same logical operation

The H59MA vendor splits the "fire alert" operation into two
opcodes so the host can choose between *beep* and *find-me*
without negotiating parameters on the wire. This matches the
§3 Channel-A convention where `0x08` (camera/find-device)
has sub-cmd `0x00` (cancel) vs `0x01` (start) — but the
0xFEE7 service puts the *duration* into the opcode rather
than into a sub-cmd, which is simpler for the short
single-frame alerts.

#### Pair with `0xC5/0xC8/0xC9` config-byte writes

The two alert opcodes share the same config-byte state at
`DAT_0082caec` (set via `0xC5`/`0xC8`/`0xC9` — see §8.1).
A host that wants to *disable* alerts without firmware reboot
can write `0` to `DAT_0082caec[3]` via `0xC5 0x00` and the
`0x50` / `0x51` opcodes will silently no-op (the
sub-cmd-byte guard will still pass but the vendor alert
helper will be a no-op via the dispatcher gate).

### 8.12 0x3c capability block (`FUN_0082c50e`)

The "what features does this watch support" answer. Sends
a **fully static 16-byte response** that contains four
feature IDs scattered across the frame body. The handler
ignores the request entirely — `0x3c` is fire-and-forget.

#### Behavior

```c
void FUN_0082c50e() {
    rsp[0]  = 0x3c;        // cmd
    rsp[1]  = 0x00;
    rsp[2]  = 0x40;        // feature ID 1
    rsp[3]  = 0x00;
    rsp[4..6]  = 0;
    rsp[7]  = 0xa0;        // feature ID 2 (split across bytes 7..8?)
    rsp[8..10] = 0;
    rsp[11] = 0x20;        // feature ID 3
    rsp[12..14] = 0;
    rsp[15] = FUN_0082b0c4(rsp, 0xf);
    FUN_0082ebdc(rsp);
}
```

The handler does *not* read `param_1` at all — there is no
request payload for `0x3c`. The four non-zero bytes
(`0x3c`, `0x40`, `0xa0`, `0x20`) are the static "feature
flags" returned on every call.

#### Response layout (16-byte static block)

```
byte  0: 0x3C                (cmd)
byte  1: 0x00
byte  2: 0x40                (feature ID 1)
byte  3: 0x00
byte  4: 0x00
byte  5: 0x00
byte  6: 0x00
byte  7: 0xA0                (feature ID 2 — high byte)
byte  8: 0x00                (feature ID 2 — low byte = 0?)
byte  9: 0x00
byte 10: 0x00
byte 11: 0x20                (feature ID 3)
byte 12: 0x00
byte 13: 0x00
byte 14: 0x00
byte 15: additive checksum
```

Note: the bytes between the non-zero entries are **all
zero** — the firmware does not populate any "feature
metadata" beyond the four flags. The host SDK is expected
to recognise `0x40` / `0xA0` / `0x20` as opaque feature
identifiers (they are likely vendor-specific feature codes
that match the H59MA SDK's `enableXxx` flags).

#### Why a static block (not a runtime read)

`0x3c` is the only 0xFEE7 opcode whose response is **hard-
coded** in the firmware binary. All other opcode handlers
either compute the response at runtime (`0x48`, `0x61`),
look up state from RAM (`0xc5`, `0xc8`, `0xc9`), or call
into a vendor function table (`0xce`). The static nature
suggests:

* The capability block is *product-line wide*: every H59MA
  v14 firmware ships with the same capabilities, so the
  block can be baked into the ROM.
* The vendor doesn't expect the watch model or feature set
  to change between firmware revisions — when it does, the
  firmware is rebuilt and the static block is regenerated.

#### `param_1` ignored

The handler signature is `void FUN_0082c50e()` (no params),
even though the dispatcher passes `param_1` (the request
frame). The decompiler optimises the unused param out
entirely. A host that sends a *non-empty* request still
gets back the same static block — the `0x40`, `0xa0`,
`0x20` flags are unconditionally emitted.

#### Pair with `0x61 'a' status` (§8.3)

`0x3c` and `0x61 'a'` are the two "what does this watch
do" answers. `0x3c` answers once per connection with the
**static feature set**; `0x61 'a'` answers continuously
with the **live status** (battery %, daily counters). A
host that wants both can:

1. Send `0x3c` after `0x48` (handshake) to learn the
   supported features once.
2. Poll `0x61 'a'` at low rate for live battery / counter
   updates.

#### Relation to the §3 "0x3c capability block"

`0x3c` is also a *Channel-A* opcode (the §3 dispatcher
at `FUN_0082d2dc` does not route `0x3c`; the byte 0x3c
falls into the `0x39 < uVar2 < 0x43` chain and reaches
`FUN_0082c50e`). So `0x3c` is in fact a *shared* opcode
between Channel-A and 0xFEE7 — the dispatcher for both
tables lands on the same handler. The host SDK can call it
from either transport.

### 8.13 0xfe vibration-pattern-from-duration (inline in `FUN_0082c944`)

The only 0xFEE7 opcode that is **fire-and-forget** with **no
response frame at all**. The dispatcher inline-calls
`FUN_00844214` with the u16 LE duration from `req[1..2]`
and returns without queuing a response.

#### Dispatcher body

```c
case 0xfe:
    FUN_00844214(*(u16 *)(param_1 + 1));
    return;
```

No `FUN_0082ebdc` is called — the watch accepts the
request, builds the pattern, and goes silent.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0xfe` | cmd (consumed by dispatcher) |
| 1..2 | `duration` (u16 LE) | vibration pattern length in **10 ms ticks**; clamped to `900` (9 s) inside `FUN_00844214` |
| 3..14 | unused | — |

The duration unit is 10 ms (the `FUN_0083dfd6(_, 0x5A0)` calls
inside `FUN_00844214` — `0x5A0 = 1440`, divided by 144 = 10).

#### `FUN_00844214` behavior

The handler is a full vibration-pattern synthesizer:

1. **Clamp**: `if (duration > 900) duration = 900`.
2. **Reset**: `FUN_00844a64()` — stop any currently-running
   vibration.
3. **Anchor RTC**: `FUN_00840f30()` — read the current RTC
   tick; the pattern is anchored to this time so it can be
   resumed across a power-cycle.
4. **Allocate** a fresh pattern record at `DAT_00844324`
   (the global "current vibration" slot).
5. **Compute the pattern** in a `while (duration != 0)` loop.
   The loop picks one of 5 intensity levels (0 = off, 1..5 =
   increasing) based on the elapsed RTC vs the pattern's
   nominal tick. The level choice is driven by the
   *elapsed-time brackets* (in RTC ticks):
   * `< 0x3C` (60 s): level 2, step 30 ticks (0x1E)
   * `< 0x50` (80 s): level 3, step 15 ticks (0x0F)
   * `< 0x5C` (92 s): level 4, step 10 ticks (0x0A)
   * `< 0x62` (98 s): level 5, step 5 ticks
   * `>= 0x62`: level 0 (off), step 30 ticks — but bumps
     the loop's "intensity counter" at `puVar1[5]`
6. **Cap** the pattern at 40 entries (`if (puVar1[0x13] > 0x27)
   break`).
7. **Commit**: `FUN_008316fe()` — start the pattern playback.

The intensity brackets are the **envelope**: a short
duration plays only the strong/quick pulses (level 2..3),
a long duration adds the weak/slow pulses (level 4..5), and
the final "off" stage cools the motor back to silent. This is
a classic "ramp down" pattern used to signal the end of a
host-driven operation.

#### Persistent pattern record (`DAT_00844324`)

| Off | Field | Notes |
|---:|---|---|
| 0 | `start_tick` (u32) | RTC tick when the pattern was armed |
| 5 | `intensity_counter` (u8) | total patterns played (caps at 5, then `0`) |
| 6 | `duration_ticks` (u16 LE) | the duration value passed by the host |
| 0xE | `first_pattern_offset` (u16) | offset into the pattern table |
| 0x13 | `next_pattern_idx` (u8) | next free slot in the pattern table |
| 0x14.. | `pattern[]` (u8 array) | up to 40 entries, each a `level` (0..5) |
| 0x3C.. | `durations[]` (u8 array) | corresponding tick durations for each entry |

The `FUN_0083dfd6(time, ticks)` helper adds `ticks` to the
running RTC. The `FUN_008267cc()` helper reads the current RTC.

#### Why no response

A vibration pattern is a **delayed side-effect**: the watch
plays the pattern over the next several seconds, and the
host wants to know "when does it finish?" not "did you
accept the pattern?". Since `FUN_00844214` returns the
expected pattern duration (via `puVar1[6]`), the host SDK
can compute the expected finish time *locally* without
needing a response frame.

A response frame would also be wasted on the BLE link
because the pattern plays for up to 9 s; the response would
arrive immediately, long before the host cares about
completion. So the no-response design trades a small
"did-you-accept" verification for lower link usage.

#### Pair with `0xc7 'D'` vibration pattern player (Channel-A)

`0xc7 'D'` (§3.2) is the *Channel-A* equivalent: the host
sends a 16-byte frame with a specific vibration pattern, the
watch plays it. The two are *functionally* the same — both
build a vibration pattern from host-supplied data and play
it. The difference is that `0xfe` takes a **single u16
duration** and *generates* a ramp-down envelope internally,
while `0xc7` takes an **explicit pattern** (presence + id +
duration + 12-byte pattern data) and plays it verbatim. A
host that wants a simple "beep for N ticks" should use
`0xfe`; a host that wants a custom tune should use `0xc7`.

#### Why `0xfe` is inline in the dispatcher

Most 0xFEE7 handlers are routed through `FUN_0082be64`
(deferred ring — see §8.1). `0xfe` is *inline* in the
dispatcher because the dispatcher needs the host-supplied
u16 duration *before* it can queue the work; the deferred
ring does not carry per-call parameters, only the raw 16-byte
frame. Inlining `0xfe` lets the dispatcher pass the duration
*directly* to `FUN_00844214` without an intermediate
indirection through `FUN_0082be64`.

### 8.14 0xc1 deferred long-fragmented response (inline in `FUN_0082c944`)

The "I will eventually send a long fragmented response" ack.
Like `0xfe` (§8.13), this opcode is **inline in the
dispatcher** — but unlike `0xfe`, it does ship an immediate
1-byte ack frame before the long payload arrives.

#### Dispatcher body

```c
case 0xc1:
    FUN_008337fa(DAT_0082caf0);          // start async HR read
    FUN_0082b938(*param_1, DAT_0082caf0, 1);  // send 1-byte ack
    return;
```

The two calls are interleaved: `FUN_008337fa(DAT_0082caf0)`
kicks off an asynchronous HR measurement that will fill
`DAT_0082caf0` later via the deferred ring worker; the
`FUN_0082b938` call sends a 1-byte fragmented frame right
now, carrying `*param_1` (the cmd byte) at byte 0 and a
checksum at byte 15 — the rest of the frame is
zero-padded.

#### `FUN_008337fa` — async-read initiator

```c
void FUN_008337fa(undefined1 *out_ptr, ..., undefined4 param_4) {
    state = DAT_00833858;
    flag  = state + 0x1c;
    if (!(*flag & 1)) {                     // not already pending
        *flag = 0;  *(state + 0x20) = 0;  *(state + 0x24) = 0;
        if (*DAT_0083389c != 1 && !FUN_00828af4()) {  // ring idle, HR not running
            FUN_0083371e(2);                       // start HR measurement mode 2
            FUN_00829c24(DAT_00833a1c, DAT_00833a18,
                         DAT_00833a14, 1, param_4); // queue work item
            *flag |= 1;
            *(state + 0x20) = out_ptr;             // store callback pointer
            return;
        }
        // ring busy OR HR running: mark "needs retry"
        *(DAT_00833858 + 0xf) = 1;
        if (out_ptr) *out_ptr = 0;
    } else {
        // already pending — update callback pointer
        *(state + 0x24) = out_ptr;
    }
}
```

The helper is a **debounced HR read initiator**:
1. If no read is already pending (`!(*flag & 1)`):
   * Clear the state struct.
   * If the deferred ring is idle *and* the HR step counter
     is not busy (`FUN_00828af4()` — same gate used by
     `0x08 findDevice` and `0x77 phoneSport`), start the HR
     measurement (`FUN_0083371e(2)` — mode 2 = one-shot
     single-record read) and queue a worker item via
     `FUN_00829c24`.
   * Otherwise mark a "needs-retry" flag at `+0xF` and
     return a zero byte via the out-pointer (if non-null).
2. If a read is already pending, just update the
   out-pointer so the *next* read uses the latest caller.

The 0x1C pending flag and the 0x24 secondary out-pointer
let the host call `0xc1` multiple times in quick succession;
only the first call actually starts an HR read, and the
later calls latch their out-pointer until the worker fires.

#### Deferred-ring worker output

When the worker eventually fires, it pushes a fragmented
response onto the 0xFEE7 notify ring:

```
byte  0: 0xC1                (cmd echo)
byte  1..N: fragmented HR data (13 B per chunk, N+1 frames)
```

The fragment count depends on how long the HR read takes —
typically 2..4 frames for a normal one-shot read. The
`FUN_0082c988` 13-byte-chunk streamer (§3.11) handles the
fragmentation.

#### Why inline in the dispatcher

Like `0xfe` (§8.13), `0xc1` is inline because the deferred
ring can't carry the "you need to also call `FUN_0082b938`"
second-call requirement. The dispatcher needs to issue two
distinct worker calls (`FUN_008337fa` to start the read,
`FUN_0082b938` to send the ack), and putting them inline
keeps them in the right order without the deferred-ring
worker needing to know about the second call.

#### Pair with `0x15 readHeartRate` (Channel-A)

`0xc1` is the 0xFEE7 vendor variant of `0x15` (§3.12). Both
start an async HR measurement and emit a fragmented payload
on completion. The differences:

| | `0x15` (Channel-A) | `0xc1` (0xFEE7) |
|---|---|---|
| Trigger | dispatcher calls `FUN_0082cf48` directly | dispatcher calls `FUN_008337fa` + `FUN_0082b938` |
| Read mode | `FUN_008279c4(idx)` — month-index | `FUN_0083371e(2)` — one-shot |
| Ack | none — payload frames only | 1-byte ack frame sent immediately |
| State machine | per-call fresh state | debounced via `flag` + secondary out-pointer |

A host that wants to poll HR records should use `0x15` (which
returns the full 292-byte record); a host that wants
notification-only push (no ack, just data) should use
`0xc1`.

#### Why the dispatcher's `FUN_0082b938(*param_1, ...)` uses `length = 1`

The second call sends a **1-byte fragmented response** — the
host sees just `[*param_1, 0, 0, ..., 0, cksum]`. The `1`
argument is the length, not a byte value. The 13-byte-chunk
streamer fills the frame with `[cmd, 0, ..., 0, cksum]` and
the fragmented HR data comes in *subsequent* frames
(emitted by the deferred-ring worker via `FUN_0082c988`).

The host SDK should:
1. Read the immediate 1-byte ack (`cmd = 0xc1`).
2. Wait for the fragmented HR data to arrive on the
   notify ring.
3. Reassemble the chunks using the standard
   `[cmd, seq, 13 data bytes, cksum]` shape.

---

## 10. Open Questions / Next Steps

1. ~~Recover the exact meaning of opcode `0x2b` mixture container fields.~~ **Resolved** — see §3.1. The 16-byte `mixture_state_t` is now fully decoded; remaining unknowns are semantic (BCD field interpretation, period-data byte meanings).
2. Identify the 32-byte `image_digest` algorithm used for OTA and the container header digest at `0x1c4`. No SHA-256 constants were found in the body; it may be computed by the bootloader or host tool.
3. ~~Determine whether the `0xFEE7` vendor service has any active protocol role in the firmware.~~ **Resolved** — see §8; it implements a second 16-byte command channel.

### 8.15 0x3e lipids read/set (`FUN_0082c550`)

The 0xFEE7 vendor-side **duplicate** of the `0x3a sub 0x04`
lipids bit-toggle. The existing docstring for `0x3e`
("SpO2 / blood-oxygen related read/set") is *wrong* —
the helper functions it calls (`FUN_008277ce` and
`FUN_008277d8`) read and write **bit 7** of the shared
config byte at `DAT_008277f0 + 0x2D`, which is the
**lipids** bit per the §3.22 / §8.8 bit map.

#### Sub-opcode dispatch

| `req[1]` | Action | Helper |
|---:|---|---|
| `0x01` (read) | `local_20[2] = FUN_008277ce()` — read bit 7 of `*(DAT_008277f0 + 0x2D)`, `>> 7` yields `0` or `1` | `FUN_008277ce` |
| other (write) | `FUN_008277d8(req[2] == 1)` — if `req[2] == 1`, set bit 7; else clear it. Response echoes `req[2]` | `FUN_008277d8` |

The handler is a *structural clone* of `0x36` (§8.8) and
`0x38` (§3.17) — same 3-byte response shape, same
"read 0x01 / write otherwise" sub-cmd pattern.

#### Persistent state (1 bit)

| Bit | Field | Owner |
|---:|---|---|
| 7 | `lipids` | `0x3e` (this handler) **and** `0x3a sub 0x04` (§3.22) |

Yes — `0x3e` and `0x3a sub 0x04` both own **bit 7** of the
same shared config byte. They are duplicates: the same
lipids bit is reachable from both `0x3a sub 0x04` (via the
`0x2C` §3.10 dispatcher) and `0x3e` (via the `0xFEE7` §8.1
dispatcher). The masks `>> 7` and `<< 7` and the write
guard `(... & 0x7F) | (param_1 << 7)` are identical, so
writing through either opcode has identical effect.

#### Response layout

```
byte  0: 0x3E                (cmd)
byte  1: req[1]              (sub-opcode echo: 0x01 read / 0x02+ write)
byte  2: 0x00 / 0x01         (lipids value on read; echoed req[2] on write)
byte  3..14: 0
byte 15: additive checksum
```

#### Why a duplicate?

`0x3e` is one of the few *opcode duplicates* in the
firmware. Two plausible reasons:

1. **Backwards compatibility with older host SDKs** that
   used `0x3e` directly. The newer `0x3a sub 0x04` is the
   preferred path for new code, but the watch keeps `0x3e`
   working so older apps don't break.
2. **Vendor-table shortcut**: the OEM vendor tables (§8.10
   `0xce` handler) reference `0x3e` directly because it's
   a single-byte opcode without sub-cmd routing — easier to
   emit from a fixed-purpose vendor test routine.

The body code (`FUN_008277ce` / `FUN_008277d8`) is *shared*
with `0x3a sub 0x04` — both handlers call the same pair of
helpers, and the helpers themselves operate on the same
shared bit. This is the second instance of "different opcode,
same underlying bit" — the first being `0x36` (HR enable)
vs the (absent) duplicate for SpO2, where the firmware
chose to keep a single channel.

#### Correcting the docstring

The original §3 opcode table listed `0x3e` as "SpO2 /
blood-oxygen related read/set" — this was incorrect. The
correct semantic (per the decompiled `>> 7` shift and the
shared-bit overlap with `0x3a sub 0x04`) is **lipids
read/set**. The SpO2 bit-toggle lives at `0x2c` (§3.10)
only; there is no 0xFEE7-side duplicate for SpO2.

If the host SDK's `enableSpo2()` function sends `0x3e`, it
will silently toggle the **lipids** bit instead, leaving
SpO2 untouched. The correct opcode for SpO2 is `0x2c` (the
Channel-A path) — which is *not* reachable from the 0xFEE7
service. A host that wants SpO2 control must use the
Channel-A path, not the 0xFEE7 path.

#### Why a §8.15 if it's a duplicate of `0x3a sub 0x04`?

The duplicate-opcode pattern is significant because it
shows the firmware's *evolution*: the older `0x3e` opcode
was kept for compatibility even after the more flexible
`0x3a sub 0x04` was added. Future firmware revisions may
remove `0x3e` once the vendor test routines stop using it,
but the lipids bit (7) will remain in the shared config
byte.

### 8.16 0x60 status-field write (`FUN_0082be90`)

The **write** side of the `0x61 'a'` status (§8.3) pair.
`0x60` lets the host push a 4-byte u32 into the same
`DAT_0082bfd4 + 0x2C` field that `0x61 'a'` reads. The
existing docstring ("ANCS/message-push related") is *wrong*
— the handler's only side effects are (a) writing the status
u32 and (b) scheduling a 100 ms timer.

#### Behavior

```c
uint FUN_0082be90(int param_1) {
    if (FUN_0082762c() == 1 && FUN_0082d754() == 0) {
        // "all-zeros ack" path
        rsp[0]  = 0x60; rsp[15] = 0x60;  // self-marker frame
        FUN_0082ebdc(rsp);
        FUN_0082fdda(100);               // 100 ms timer
        return 0x60;
    }
    // "store u32" path
    rsp[0]  = 0x60; rsp[15] = 0x60;
    FUN_0082ebdc(rsp);
    uint32_t v = ((req[3] << 16) | (req[4] << 24)) |
                 (req[1]       )          |
                 (req[2] << 8);
    *(u32*)(DAT_0082bfd4 + 0x2C) = v;
    return 0x60;
}
```

The handler has **two paths** that both send the same
self-marker response frame `[0x60, 0, 0, ..., 0, 0x60]`:
* "Happy" path: state is good → schedule a 100 ms timer
  (the standard "next tick" push that the §8.3 status push
  uses to refresh the live battery / counter data).
* "Write" path: state is bad → write the 4-byte packed
  value from `req[1..4]` into `DAT_0082bfd4 + 0x2C`.

#### Self-marker pattern (like `0x90` §8.6 and `0x96` §8.4)

The handler writes `0x60` at **both byte 0 and byte 15** of
the response — the same self-marker pattern used by `0x90`
(self-marker echo) and `0x96` (reset-state). The byte-15
`0x60` is *intentional*, not a checksum. The host verifies
by `byte 0 == 0x60 && byte 15 == 0x60`.

#### Why a §8.16 if it's a "tiny" handler?

The handler is short (~15 instructions), but it ties
together three important subsystems:

1. The **`DAT_0082bfd4 + 0x2C` status field** that
   `0x61 'a'` reads (§8.3) — i.e. `0x60` *writes* what
   `0x61 'a'` *reads*. Without documenting `0x60`, the
   `0x61 'a'` status push is a black box.
2. The **same `FUN_0082762c()` / `FUN_0082d754()` state
   checks** used by `0x61 'a'` (§8.3). The two handlers
   share the "is the firmware in the right mode?" guard.
3. The **same `DAT_0082bfd4` base pointer** used as the
   state anchor for both `0x60` and `0x61 'a'`. `DAT_0082bfd4`
   is the "live status" struct that backs the entire
   battery / counter subsystem; the `+0x2C` field is the
   "current snapshot" u32 that the host reads via `0x61 'a'`.

#### Request layout

| Byte | Field | Notes |
|---:|---|---|
| 0 | `0x60` | cmd (consumed by dispatcher) |
| 1..4 | `value` (4 B LE) | packed u32 to write to `DAT_0082bfd4 + 0x2C` |
| 5..14 | unused | — |

The 4-byte packed layout is `req[1] | (req[2] << 8) | (req[3] << 16) | (req[4] << 24)` — i.e.
**big-endian order of the request bytes** maps to LE u32 in
the firmware. The host packs the value the same way it
reads it back from `0x61 'a'` (the `0x61 'a'` response has
the same byte layout — see §8.3).

#### Pair with `0x61 'a'` (§8.3)

| | `0x60` | `0x61 'a'` |
|---|---|---|
| Direction | host → watch (write) | watch → host (read) |
| Field | `DAT_0082bfd4 + 0x2C` | same |
| Use case | inject a fake status (test rigs, vendor QA) | read live battery / counter |

A test rig that wants to verify the host's status-decoding
path can use `0x60` to write a known u32 and `0x61 'a'` to
read it back. A production host only uses `0x61 'a'`.

#### Why the byte-15 `0x60`?

Like `0x90` self-marker (§8.6) and `0x96` reset-state (§8.4),
the byte-15 `0x60` is a **handshake / self-identification**
marker — the response says "the watch is in `0x60` mode and
this frame is a `0x60` ack". The host SDK that consumes
`0x60` should special-case the byte-15 verification rather
than trusting the additive checksum (which will be `0xC0`,
not `0x60`).
