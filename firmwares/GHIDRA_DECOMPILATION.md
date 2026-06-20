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

| Cmd | Handler | Notes |
|---|---|---|
| `0x01` | `FUN_0082f1a4` | OTA start ack — calls state callback `(1, 0)` |
| `0x02` | `FUN_0082f1b6` | OTA init — expects 9-byte payload, sub-cmd `0x01`/`0x04`; stores image size and metadata; sets OTA state to `2` |
| `0x03` | `FUN_0082f240` | OTA data packet — reassembles image, validates first 0x50 bytes, copies a 32-byte digest, writes to flash |
| `0x04` | `FUN_0082f378` | OTA check — validates state `3` and accumulated size matches expected |
| `0x05` | `FUN_0082f3b4` | OTA end — finalizes, resets sensors/BLE, reboots after delays |
| `0x07` | `FUN_0082f410` | OTA sub-ack — calls state callback `(7, 0)` |
| `0x11` | `FUN_0082f5a2` | Read sleep summary for a day offset |
| `0x12` | `FUN_0082f50c` | Read detailed sleep data |
| `0x21`, `0x22`, `0x23`, `0x24` | — | ACK with code `2` |
| `0x27` | `FUN_0082fada` | Read sleep records (sends both `0x27` night and `0x3e` nap records) |
| `0x29`, `0x3b`, `0x13` | — | no-op |
| `0x2a` | `FUN_00833bbc` | Read activity/sport summary for last N days |
| `0x2c` | `FUN_0082f8ec` | Alarm read/write (sub `0x01` read, `0x02` write) |
| `0x41` | `FUN_008311b8` | File list (cmd `0x41`) |
| `0x43`, `0x46` | `FUN_008311b8` | File delete / file init (routed to same handler) |
| `0x47` | `FUN_008347fa` | no-op |
| `0x4b` | `FUN_00830460` | no-op |
| `0x5a` | `FUN_0082f6ec` | Device info/config (sub `0x01` read info, `0x02` write config, `0x03` read version strings, `0x04` reset) |

Unrecognized commands fall through to `FUN_0082ee00(cmd, 0)` (NAK code `0`).

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
| `0x2b` | `menstruation` (mixture container) | `0x0082ba54` | Sub `0x01`/`0x02` read/write mixture data; builds `0x2b` response with additive checksum. |
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

## 8. Vendor `0xFEE7` GATT Service

The firmware attribute table declares a fourth vendor service `0x0000fee7` at body offset `0x008456bc` (UUID bytes `e7 fe 00 00 ...`). Characteristic UUIDs are laid out nearby:

| Char | Body UUID offset |
|---|---|
| `0xfea1` write+CCCD | `0x008456f2` |
| `0xfec9` read | nearby |
| `0xfea2` notify+CCCD | nearby |
| `0x2a00` Device Name | nearby |

No code references to the `0xFEE7` service endpoints were located during this decompilation pass; the service is present in the GATT table but its protocol usage (if any) is not exercised by the Channel A/B paths documented above. The OpenWatch app currently probes it during discovery only.

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

1. Recover the exact meaning of opcode `0x2b` mixture container fields.
2. Identify the 32-byte `image_digest` algorithm used for OTA and the container header digest at `0x1c4`. No SHA-256 constants were found in the body; it may be computed by the bootloader or host tool.
3. Determine whether the `0xFEE7` vendor service has any active protocol role in the firmware.
