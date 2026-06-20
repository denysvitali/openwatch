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
| `0x0e` | `bpReadConform` | `0x0082cb28` | If sub-byte `0` → `FUN_00834410()` + `FUN_0082c0a4()`. |
| `0x15` | `readHeartRate` | `0x0082cf48` | Reads heart-rate record by index; returns `0x15` multi-frame data or `0xff15` error — see §3.12. |
| `0x18` | `displayClock` | `0x0082ccb6` | Sets watch-face / clock display — see §3.5. |
| `0x1e` | `realTimeHeartRate` | `0x0082d20c` | Sub `0x01` starts 60s HR measurement, `0x02` stops, `0x03` resets timer — see §3.13. |
| `0x25` | `setSitLong` | `0x0082d284` | Writes sedentary config — see §3.9. |
| `0x26` | `readSitLong` | `0x0082d258` | Reads sedentary config — see §3.9. |
| `0x2b` | `menstruation` (mixture container) | `0x0082ba54` | Sub `0x01`/`0x02` read/write mixture data; cycle-phase detector + notification sender — see §3.1. |
| `0x2c` | `bloodOxygenSetting` | `0x0082d1c2` | Sub `0x01` reads SpO2 setting, `0x02` writes it — see §3.10. |
| `0x37` | `pressureSetting` | `0x0082caa6` | Reads/sets pressure config; uses `FUN_008344fe`. |
| `0x38` | `pressure` | `0x0082ca54` | Sub `0x01` reads pressure value, else sets pressure unit. |
| `0x39` | `hrvSetting` | `0x0082c9da` | Reads/sets HRV config; uses `FUN_0083468e`. |
| `0x3a` | `sugarLipidsSetting` | `0x0082cc1e` | Sub `0x03`/`0x04` read/write sugar/lipids settings. |
| `0x3b` | `uvSetting` / `touchControl` | `0x0082cbc8` | Read/write UV/touch config byte at `DAT_0082cfe8 + 8`. |
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

| Opcode(s) | Action | Helper |
|---|---|---|
| `0x00..0x2a` | switch8 table at `0x82c61d` (43 entries) | per-entry thunk |
| `0x2b, 0x37, 0x38, 0x3a, 0x3b, 0x43 'C', 0x48 'H', 0x72, 0x7a, 0x7d, 0x81, 0xa1, 0xc6, 0xc7 'D', 0xff` | Defer to the deferred-command ring | `FUN_0082be64` |
| `0x36` | Heart-rate related read/set | `FUN_0082c112` |
| `0x39` | HRV setting | `FUN_0082c9da` |
| `0x3c` | Fixed capability block `[0x3c,0,0x40,0xa0,0x20,…]` | `FUN_0082c50e` |
| `0x3e` | SpO2 / blood-oxygen related read/set | `FUN_0082c550` |
| `0x48 'H'` | Handshake — 15-byte device-info block | `FUN_0082bf40` |
| `0x50 'P'` | **Inline** alert: `FUN_0082994c(0x14, 0x10, 1, 0x19)` + `FUN_0082a5c8(8)` (motor + UI) | inline |
| `0x51 'Q'` | "Find phone" / alert trigger | `FUN_0082c5b8` |
| `0x60` | (handler) | `FUN_0082be90` |
| `0x61 'a'` | Status response (battery / daily counters) | `FUN_0082bee6` |
| `0x69 'i'` | Multi-step mode control (start/stop/cancel) | `FUN_0082c2f4` |
| `0x6a 'j'` | Continuation of `0x69` mode control | `FUN_0082c1e2` |
| `0x7b, 0xb0, 0xc2, 0xcc, 0xf0, 0xf1` | No-op (early return) | — |
| `0x90` | Echo `[0x90]` | `FUN_00827ad2` |
| `0x91` | Echo `[0x91]` | `FUN_00827aee` |
| `0x92` | (handler) | `FUN_00827b14` |
| `0x93` | (handler) | `FUN_00827c4a` |
| `0x94` | (handler) | `FUN_00827b2e` |
| `0x95` | (handler) | `FUN_00827b54` |
| `0x96` | Sends `[0x96,0,0,0x96,…]` and resets state | `FUN_00827b7c` |
| `0x97..0x9f` | switch8 table at `0x82c6e1` (9 entries) | per-entry thunk |
| `0xa0` | (handler — see also the `0x97..0x9f` switch8) | `FUN_00827b16` |
| `0xbf` | (handler) | `FUN_0082ba94` |
| `0xc0` | (handler) | `FUN_0082bb0c` |
| `0xc1` | Sends a long/fragmented response: `FUN_008337fa(DAT_0082caf0)` + `FUN_0082b938(*param_1, DAT_0082caf0, 1)` | inline |
| `0xc3` | If `param_1[2] == 1` → `FUN_0082dfde()`; then drive OTA state machine via `FUN_0082fe52(4 or 0, 0)` based on `param_1[1]` (1=push 4, 2=push 0, other=return) | inline |
| `0xc4` | No-op | `FUN_00830462` |
| `0xc5` | If `param_1[1] == 1` → `DAT_0082caec[3] = 1`; else `DAT_0082caec[3] = 0` | inline |
| `0xc8` | Same as `0xc5` but writes `DAT_0082caec[4]` | inline |
| `0xc9` | `DAT_0082caec[5] = param_1[1]` | inline |
| `0xcd` | (handler — alarm-like 16-bit setter) | `FUN_0082be12` |
| `0xce` | Factory/test sub-commands (`0x01`, `0x02`, `' '`, `'!'`, `'"'`) | `FUN_0082bcde` |
| `0xfe` | `FUN_00844214(*(u16*)(param_1 + 1))` — vibration pattern from a duration arg | inline |
| other | Vendor NAK: `FUN_0082bcba(opcode)` | `FUN_0082bcba` |

#### Deferred-command ring (`FUN_0082be64`)

The 15 opcodes routed to `FUN_0082be64` (including all the
Channel-A opcodes the watch knows about plus the
0xFEE7-specific `0xC7 'D'` and `0xFF`) are **not** handled
synchronously. Instead the dispatcher copies the 16-byte
request into a 10-slot ring at `DAT_0082bfcc + 4`, increments
the slot index, and calls `FUN_00827124(0, DAT_0082bfd0)` to
schedule a worker that drains the ring at a later tick. This
is how the watch avoids a single long 0xFEE7 frame from
blocking the BLE link while a CPU-heavy handler (e.g.
`0x77 phoneSport` or `0x43 readDetailSport`) runs.

The decompiler text has the ring copied as

```c
memcpy(ring + 4 + (*(u16*)(ring + 2)) * 0x10, param_1, 0x10);
*(u16*)(ring + 2) = (*(u16*)(ring + 2) + 1) % 10;
FUN_00827124(0, ring_worker);
```

— i.e. a circular buffer of 10 frames with a single writer
(the dispatcher) and a single reader (the worker). The 10-slot
size is the same as the Channel-A dispatcher at
`FUN_0082d2dc`.

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

The two `0x82c61d` and `0x82c6e1` switch8 tables route the
"long tail" of opcodes that don't have explicit branches:

* `0x82c61d` (43 entries, base `0x82c61d`): covers opcodes
  `0x00..0x2a`. Most entries are `0x99` (a single "no-op"
  thunk); non-default entries route to small per-feature
  thunks (e.g. `0x01`/`0x06`/`0x08`/`0x0e`/`0x10` all share
  the same `0x23` slot → likely an "echo ack" path).
* `0x82c6e1` (9 entries, base `0x82c6e1`): covers opcodes
  `0x97..0x9f`. The default slot is `0x37` (→ default no-op),
  so most of the 0x97..0x9f range is also a no-op; the
  visible non-default entries handle vendor-only sub-cmds.

A host should treat both ranges as *reserved* unless it can
match a specific response shape from the watch.

#### Relationship to §8 opcode map

The opcode → handler map **above** supersedes the original §8
table (which only listed the *immediately-routed* opcodes).
The §8 table is now strictly a subset: the "deferred"
opcodes (`0x43`/`0x48`/`0x7a`/etc.) are still in the
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
