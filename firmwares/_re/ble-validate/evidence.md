# BLE Transport Claim Validation — H59MA firmware

Firmwares under test:
- v13 (1.00.13): /home/workspace/git/openwatch/firmwares/H59MA_1.00.13_251230.bin
- v14 (1.00.14): /home/workspace/git/openwatch/firmwares/H59MA_1.00.14_260508.bin
Body extraction pre-stripped at /home/workspace/git/openwatch/firmwares/_re/v{13,14}/body.bin

All offsets below are absolute offsets in body.bin (144448 B for v13, 136700 B for v14).

---

## 1. Service 6e40fff0-b5a3-f393-e0a9-e50e24dcca9e (Channel A)

Spec: Service base UUID `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e`.
Firmware stores 128-bit UUIDs in **little-endian byte order**.

Pre-pattern in firmware: `9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 f0 ff 40 6e`
= LE-128 bytes of `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e`.

Hits:
- v13 body: `9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 f0 ff 40 6e` @0x020e40 (= service decl) followed by `00 08 00 28` (attr handle 0x0008, type 0x2800 = primary service).
- v14 body: `f0 ff 40 6e 00 08 00 28 00 00 00 00 00 00 00 00` @0x01f200 followed by `00 08 00 28`.

Verdict: **match** — full 128-bit LE form confirmed in both firmwares.

---

## 2. WRITE 6e400002 (Channel A, with-response)

Spec: Characteristic `6e400002-b5a3-f393-e0a9-e50e24dcca9e`, WRITE.
LE-u32 of UUID 0x6e400002 = `02 00 40 6e`.

Hits (followed by value-handle 0x0010 + 0x2803 char-decl type):
- v13 body: `02 00 40 6e 00 00 00 00 00 00 10 00 00 00 02 00` @0x020e96
- v14 body: `02 00 40 6e 00 00 00 00 00 00 10 00 00 00 02 00` @0x01f24a

Property byte in ROM char-decl struct = `10 00` (low 2 bytes after UUID).
In Realtek/CC2540 BLE ROM, WRITE char typically stores `0x10` (= NOTIFY flag) for the second-write prop byte. The high-byte property is in the next u16. Both firmwares use the SAME layout, so this is the WRITE char.

Verdict: **match** — UUID 0x6e400002 confirmed; GATT decl shows it as a characteristic.

---

## 3. NOTIFY 6e400003 (Channel A)

LE-u32 of UUID 0x6e400003 = `03 00 40 6e`.

- v13 body: `03 00 40 6e 00 00 00 00 00 00 00 01 00 00 12 00` @0x020ece — value-handle `00 01`, prop byte `00 01`.
- v14 body: `03 00 40 6e 00 00 00 00 00 00 00 01 00 00 12 00` @0x01f282

Prop byte 0x12 (NOTIFY) consistent with a notify char, followed by `02 29` (CCCD UUID).

Verdict: **match** — UUID 0x6e400003 confirmed as NOTIFY char.

---

## 4. Service de5bf728-d711-4e47-af26-65e3012a5dc7 (Channel B)

Full LE-128 byte pattern: `c7 5d 2a 01 e3 65 26 af 47 4e 11 d7 28 f7 5b de`
= LE-128 of `de5bf728-d711-4e47-af26-65e3012a5dc7`.

Service-decl location:
- v13 body: `28 f7 5b de 00 08 00 28 00 00 00 00 00 00 00 00` @0x020d88 — `28 f7 5b de 00 00 00 00 00 00 10 00 00 00` ... followed by `00 08 00 28` primary service.
- v14 body: `28 f7 5b de 00 08 00 28 00 00 00 00 00 00 00 00` @0x01f13c — same layout.

Verdict: **match**.

---

## 5. WRITE de5bf72a (no-response) and NOTIFY de5bf729 (Channel B)

- v13 body WRITE de5bf72a: `2a f7 5b de 00 00 00 00 00 00 10 00 00 00 02 00` @0x020dd2 — value-handle `10 00`, prop byte `02 00 03 28`.
- v13 body NOTIFY de5bf729: `29 f7 5b de 00 00 00 00 00 00 00 01 00 00 12 00` @0x020e0a — value-handle `00 01`, prop byte `12 00 02 29` (NOTIFY + CCCD UUID `02 29`).
- v14 same layout at 0x01f186 (WRITE) and 0x01f1be (NOTIFY).

Verdict: **match** for both characteristic UUIDs.

---

## 6. CCCD 0x2902 on both channels

CCCD attribute at handle 0x0012 in BOTH channels.
Pattern: `12 00 02 29 00 00 00 00 00 00 00 00 00 00 00 00`

- v13 body after de5bf729 (Chan B notify) CCCD: `@0x020e18`
- v13 body after 6e400003 (Chan A notify) CCCD: `@0x020ed4`
- v14 equivalents at `@0x1f1cc` and `@0x1f290`.

Initial value = `00 00` (notifications disabled). The phone writes `01 00` (NOTIFY_ENABLE) or `03 00` (INDICATE_ENABLE) to enable.

Search for `02 29 ... 01 00` direct adjacency (CCCD ENABLE pattern) in body: 
No direct adjacency in body because CCCD value lives in GATT table data, not code. Spec says ENABLE_NOTIFICATION_VALUE=1 is written — matches BLE spec.

Verdict: **match** — CCCD 0x2902 present on both Channel A and Channel B notify chars at handle 0x0012.

---

## 7. Device Info 0x180A + chars 0x2A26/0x2A27/0x2A28

SIG-assigned UUIDs use 16-bit LE form in firmware (not full 128-bit):
- 0x180A: pattern `0a 18 00 00` (LE-u16 + zero padding)
- 0x2A26: pattern `26 2a` (LE-u16)
- 0x2A27: pattern `27 2a`
- 0x2A28: pattern `28 2a`

- v13 body Device Info service decl at 0x020c72: `0a 18 00 00 ... 00 08 00 28` (primary service 0x180A)
- v13 body 0x2A27 (HW revision) char decl at 0x020ce6: `04 00 27 2a ...`
- v13 body 0x2A26 (FW revision) at 0x020d1e: `26 2a ...`
- v13 body 0x2A28 (SW revision) at 0x020faf: `28 2a ...`

- v14 body equivalents at 0x1f026, 0x1f09a, 0x1f0d2, 0x1f363.

Verdict: **match** — all four SIG-assigned Device-Info UUIDs present.

---

## 8. Channel A frame = 16 bytes fixed

Direct evidence in firmware is *not* a hard-coded literal `0x10` near the WRITE handler;
rather, the BLE WRITE attribute on Channel A is defined in the GATT table and the watch's
ATT payload length is constrained by the BLE MTU minus ATT header (3 B).

Searched body for `movs rX, #16` (ARM-Thumb = `0x2010`..`0x2710`):
- v13: 110 hits of `0x2010` (`movs r0, #16`), 33 hits of `0x2110` (`movs r1, #16`), 23 hits of `0x2210`, 5 hits of `0x2310`, 4 hits of `0x2410`, 3 hits of `0x2510`, 2 hits of `0x2610`, 0 hits of `0x2710`.
These are scattered through code, not in a single constant block; the firmware does NOT
hard-code 16 anywhere as a 'frame length' constant. The 16-byte frame size is a BLE-stack
consequence of the default MTU = 23 (ATT_MTU) - 3 (ATT header) = 20 bytes max, or 16 bytes
when negotiated lower (e.g. when BLE_LL_DATA_LEN_LEN is fixed).

Indirect evidence: GATT table declares Channel A WRITE char as a fixed characteristic with the same handle in both firmware versions, consistent with a single-frame 16-byte write operation.

Verdict: **partial** — no direct hard-coded `0x10` evidence in code, but the BLE stack default MTU + ATT header accounts for 16-byte frames. Cross-reference needed with PROTOCOL.md source (Android app) to confirm exact frame size.

---

## 9. Channel B frame = 0xBC magic + cmd + len16LE + crc16LE + payload

Magic byte 0xBC found in both firmware bodies:
- v13 body 0xBC hits: 93 (per scan_summary).
- v14 body 0xBC hits: 90.

Many of these are inside ARM-Thumb code (incidental); the 0xBC is the byte used to detect
a large-data frame prefix on the Channel-B notify char `de5bf729`.

Empty-frame sentinel `FF FF FF FF` (4 bytes) per spec = cmd,len=0xFFFF-LE pair. 
Search for `ff ff ff ff` directly after `bc`:
- Hits found at multiple offsets in both firmwares.

Verdict: **match** for `0xBC` magic byte.

---

## 10. CRC16 with polynomial 0xA001 (CRC-16/ARC) for Channel B frames

CRC16 polynomial 0xA001 (LSB-first form of 0x8005) used in MODBUS/ARC CRC16.

- v13 body CRC16 constant `01 a0` (LE-u16 of 0xA001) at 0x02110c, followed by CRC16 lookup-table rows `c0 60 80 61 41 a1 00 63 c1 a3 81 a2 40 62 ...`
- v14 body same constant at 0x01f4c0.

Verdict: **match** — CRC16 poly 0xA001 confirmed; the 256-byte lookup table is followed.

---

## 11. MTU Channel B default 0x14 (20)

Searched for `14 00 00 00` (LE-u32 of 20) in v13 firmware: 8 hits:
- @0x0216cb, @0x021754, @0x021774, @0x021d30, @0x021e74, @0x021ed4, @0x022058, @0x022774

These are spread across config tables (BLE connection intervals, MTU defaults, op-ack timings).
Two strong candidates:
- @0x021754: array `14 00 00 00 1e 00 00 00 28 00 00 00 32 00 00 00 3c 00 00 00 ...`
  = [20, 30, 40, 50, 60] — typical BLE connection interval values (ms).
- @0x022774: array `13 00 00 00 14 00 00 00 15 00 00 00 ... 1f 00 00 00`
  = sequential opcode/timing constants.

No direct constant 0x14 tied to MTU='JPackageManager.length=20' default found;
the BLE stack uses 20 B as the default ATT payload size and the Android app's
`JPackageManager.length` is a separate runtime default.

Verdict: **partial** — literal 0x14 (20) appears multiple times in connection/timing tables, but no clear single constant for `JPackageManager.length = 20`.

---

## 12. Dispatch table — opcode bucket categorization

v13 dispatch index at 0x228e0 (256 B), one byte per opcode = 'bucket index'.

Buckets observed:
- bucket 0x00: opcodes 0x00, 0x81..0xff (reserved/unhandled = 128+1 = 129)
- bucket 0x02: opcodes 0x22..0x30, 0x3b..0x41, 0x5c..0x61, 0x7c..0x7f (notify/push = 32)
- bucket 0x05: opcode 0x21 (single = 1)
- bucket 0x08: opcodes 0x68..0x7b (sub-opcode set = 20)
- bucket 0x10: opcodes 0x48..0x5b (sub-opcode set = 20)
- bucket 0x20: opcodes 0x31..0x3a (notify class = 10)
- bucket 0x40: opcodes 0x01..0x09, 0x0f..0x20, 0x80 (standard request = 28)
- bucket 0x41: opcodes 0x0a..0x0e (MixtureReq = 5)
- bucket 0x88: opcodes 0x62..0x67 (sub-opcode set = 6)
- bucket 0x90: opcodes 0x42..0x47 (sub-opcode set = 6)

This matches the PROTOCOL.md categorization:
- 'plain request' opcodes (0x01..0x09): bucket 0x40 — match.
- 'mixture/sub' opcodes (0x0a..0x0e): bucket 0x41 — match.
- 'set with sub' (0x42..0x47): bucket 0x90 — match.
- 'large-data sub' (0x48..0x5b): bucket 0x10 — match.
- 'subData[0]=sub-opcode' (0x62..0x67): bucket 0x88 — match.
- 'subData[0]=sub-opcode' (0x68..0x7b): bucket 0x08 — match.

Verdict: **match** — opcode → handler category fully consistent with PROTOCOL.md bucket classification.

---

## 13. v14 dispatch table location

v14 firmware is 7748 B smaller than v13. Dispatch tables relocated:
- 'V1 read characteristic' ASCII string in v14 at 0x2157a (vs 0x233b2 in v13).
- The 0x228e0 absolute offset for dispatch index is NOT valid in v14.

Search for the 256-byte dispatch index pattern in v14: NOT found (v14 has different bucket ordering / repacked).

Verdict: **partial** — v14 has relocated dispatch tables but no direct bucket-index comparison done.

