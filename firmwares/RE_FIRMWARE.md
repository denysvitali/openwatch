# H59MA Firmware Reverse-Engineering Notes

These notes cover the two H59MA / Oudmon firmware images currently present in
this directory:

| Version | Container | Body size | SHA-256 |
|---|---:|---:|---|
| `H59MA_1.00.13_251230` | `H59MA_1.00.13_251230.bin` | `0x23440` / 144448 | `7347dc5fe7c552d4f0fb93cffa2dd9cab6945b5628900705a07eb7a357781b65` |
| `H59MA_1.00.14_260508` | `H59MA_1.00.14_260508.bin` | `0x215fc` / 136700 | `22fab44e1ee6f13972dec7e3bdde2da5719f962d518e36beb931f06800c3e82b` |

The container header is `0x450` bytes. Unless stated otherwise, offsets below
are offsets into the extracted `body.bin`. Add `0x450` to get the corresponding
container-file offset.

> **See also [`R2_ANALYSIS.md`](./R2_ANALYSIS.md)** — a verified, instruction-level
> radare2 deep-dive that extends and *corrects* several claims in this file (notably:
> no embedded JPEG, a 4th `0xfee7` GATT service, flash load base `0x00826400`,
> Realtek RTL8762x "Bee" stack, and the `build_time`/opcode-bucket reinterpretations).

Analysis used radare2 6.1.4 in raw Thumb mode:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex firmwares/_re/v13/body.bin
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex firmwares/_re/v14/body.bin
```

## Firmware Layout

| Region | v13 body offset | v14 body offset | Notes |
|---|---:|---:|---|
| ARM/Thumb code and const data | `0x00000..` | `0x00000..` | Raw payload has no ELF symbols; r2 auto-analysis finds only limited function boundaries. |
| Device Information GATT table | `0x20c72` | `0x1f026` | Primary service `0x180a`, with `0x2a25`, `0x2a27`, `0x2a26`, `0x2a23`, and later `0x2a28`. |
| Channel B GATT table | `0x20d7c` | `0x1f130` | Large-data / OTA service and characteristics. |
| Channel A GATT table | `0x20e40` | `0x1f1f4` | `6e40fff0` command service and `6e400002/3` characteristics. |
| CRC-16 lookup table | `0x2100c` | `0x1f3c0` | Canonical reflected `0xa001` table for CRC-16/MODBUS. |
| BLE/RTOS strings and consts | `0x218c4..0x21b54` | `0x1fc78..0x1ff08` | Includes `gatts_add_client`, `le_vendor_*`. |
| Command literal table | `0x21b58` | `0x1ff0c` | Contains opcode-like values `0x00..0x0b`, `0x50,0x51,0x52,0x53,0x55,0x56,0x58,0x5a`, then other short tables. |
| v13 opcode bucket table | `0x22490` | not found in same form | One byte per opcode in v13. v14 appears repacked or generated differently. |
| `"V1 read characteristic"` string | `0x22f62` | `0x2112a` | Useful anchor near BLE read characteristic data. |
| Embedded JPEG | `0x21eef` | `0x202a3` | Asset, not protocol code. |

## BLE GATT Tables

The firmware stores 128-bit UUIDs in little-endian byte order.

| Item | UUID | v13 body offset | v14 body offset |
|---|---|---:|---:|
| Device Info service | `0000180a-0000-1000-8000-00805f9b34fb` | `0x20c72` | `0x1f026` |
| HW revision char | `00002a27-0000-1000-8000-00805f9b34fb` | `0x20ce6` | `0x1f09a` |
| FW revision char | `00002a26-0000-1000-8000-00805f9b34fb` | `0x20d1e` | `0x1f0d2` |
| SW revision char | `00002a28-0000-1000-8000-00805f9b34fb` | `0x20faf` | `0x1f363` |
| Channel B service | `de5bf728-d711-4e47-af26-65e3012a5dc7` | `0x20d7c` | `0x1f130` |
| Channel B write | `de5bf72a-d711-4e47-af26-65e3012a5dc7` | `0x20dca` | `0x1f17e` |
| Channel B notify | `de5bf729-d711-4e47-af26-65e3012a5dc7` | `0x20dfc` | `0x1f1b2` |
| Channel B CCCD | `00002902-0000-1000-8000-00805f9b34fb` | `0x20e18` | `0x1f1cc` |
| Channel A service | `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` | `0x20e40` | `0x1f1f4` |
| Channel A write | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | `0x20e8a` | `0x1f238` |
| Channel A notify | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | `0x20ec2` | `0x1f274` |
| Channel A CCCD | `00002902-0000-1000-8000-00805f9b34fb` | `0x20ed4` | `0x1f290` |

This confirms the two-channel transport described in `PROTOCOL.md`: Channel A
is the fixed command channel, and Channel B is the large-data/file/OTA channel.

## Channel B Parser And CRC

The clearest protocol code path is the Channel-B reassembly parser:

| Function / block | v13 body offset | v14 body offset | Evidence |
|---|---:|---:|---|
| First-fragment parser | `0x8c32..0x8cae` | `0x8bea..0x8c66` | Checks minimum length `>= 6`, compares byte 0 with `0xbc`, copies cmd byte, reads little-endian length from bytes 2/3 and little-endian CRC from bytes 4/5, copies payload from byte 6 onward. |
| Continuation-fragment path | `0x8cb4..0x8cde` | `0x8c6c..0x8c96` | Appends later notify fragments until accumulated payload length reaches the header length. |
| Packet timer label | `0x8d44` | `0x8cfc` | ASCII `m_ble_packet_timer_id`, tied to fragmented-packet timeout handling. |
| CRC helper A | `0x8d5c..0x8d7c` | `0x8d14..0x8d34` | Init `0xffff`, table-driven update: `(crc ^ byte) & 0xff`, table index `* 2`, `crc = (crc >> 8) ^ table[index]`. |
| CRC helper B | `0x8d7e..0x8d9a` | `0x8d36..0x8d52` | Same reflected CRC loop with alternate argument order. |
| CRC table pointer | `0x8da0 -> 0x2100c` | `0x8d58 -> 0x1f3c0` | Points at the CRC-16/MODBUS lookup table. |

The parser proves the Channel-B frame header:

```text
byte 0      magic 0xbc
byte 1      cmd/action id
byte 2..3   payload length, little-endian u16
byte 4..5   payload CRC, little-endian u16
byte 6..    payload bytes
```

The CRC routine uses init `0xffff` and the reflected `0xa001` table, so the
algorithm is CRC-16/MODBUS, calculated over the payload bytes.

## Channel A / Command Dispatch Data

The firmware confirms the Channel-A service/characteristic UUIDs, but the fixed
16-byte command packet format remains better evidenced by the Android SDK code
than by a single obvious firmware routine.

The v13 body does contain a useful one-byte opcode bucket table at `0x22490`.
The first entries are:

```text
opcode 0x00 -> 0x00
opcode 0x01..0x09 -> 0x40
opcode 0x0a..0x0e -> 0x41
opcode 0x0f..0x20 -> 0x40
opcode 0x21 -> 0x05
opcode 0x22..0x30 -> 0x02
opcode 0x31..0x3a -> 0x20
opcode 0x3b..0x41 -> 0x02
opcode 0x42..0x47 -> 0x90
opcode 0x48..0x5b -> 0x10
opcode 0x5c..0x61 -> 0x02
opcode 0x62..0x67 -> 0x88
opcode 0x68..0x7b -> 0x08
opcode 0x7c..0x7f -> 0x02
opcode 0x80 -> 0x40
opcode 0x81..0xff -> 0x00
```

This bucket shape lines up with the APK-derived categories in `PROTOCOL.md`:
plain request, mixture read/write/delete, sub-opcode families, and notify/push
families. The exact v14 table did not appear as the same contiguous byte table;
v14 does keep the same `0x21b58`-style command literal table relocated to
`0x1ff0c`.

## Address Conversion

Examples:

| Meaning | v13 body | v13 container | v14 body | v14 container |
|---|---:|---:|---:|---:|
| Channel B parser `cmp byte0, 0xbc` | `0x8c5a` | `0x90aa` | `0x8c12` | `0x9062` |
| CRC table start | `0x2100c` | `0x2145c` | `0x1f3c0` | `0x1f810` |
| Channel A service UUID | `0x20e40` | `0x21290` | `0x1f1f4` | `0x1f644` |
| Channel B service UUID | `0x20d7c` | `0x211cc` | `0x1f130` | `0x1f580` |
| v13 opcode bucket table | `0x22490` | `0x228e0` | n/a | n/a |
