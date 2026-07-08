# Full Opcode Inventory — H59MA v14

Date: 2026-07-08  
Base: flash = body + `0x00826400`  
Evidence: [`../protocol-complete/evidence.md`](../protocol-complete/evidence.md)

---

## Coverage

| Surface | Enumerated | Wire-complete | Live-only remainder |
|---|---:|---:|---|
| Channel-A deferred tree | 27 cmp targets | 24 active + 2 noop | field units in a few history opcodes |
| Channel-A immediate low switch | 0x00..0x27 slots | 10 named + deferred set + NAK default | — |
| Channel-A / vendor high | `0x90..0xa0` + cascade | all | `0xa0` labels |
| Channel-B async low OTA | `0x00..0x10` | OTA `01..05,07` | battery refuse path live timing |
| Channel-B async cascade | `0x11..0x5a` | known set | sleep slot units |
| File-table fieldIds | 11 | offsets/widths | product names |

**Overall residual static coverage: ~92%.**

---

## A. Channel-A deferred dispatcher (`0x0082d2dc`)

Drain BL sites → handlers. Unmatched opcodes fall through to head advance (silent).

| Opcode | Name | Handler flash | Body | Drain BL site | Notes |
|---:|---|---:|---:|---:|---|
| `0x01` | setTime | `0x0082bb4e` | `0x574e` | `0x0082d3fe` | |
| `0x06` | dnd | `0x0082d298` | `0x6e98` | `0x0082d380` | |
| `0x08` | camera/find sub | inline | — | `0x0082d414` | sub on `frame[1]`: 0,1,0xab |
| `0x0e` | bpReadConform | `0x0082cb28` | `0x6728` | `0x0082d406` | |
| `0x14` | *(noop)* | — | — | advance | compare present, no BL |
| `0x15` | readHeartRate | `0x0082cf48` | `0x6b48` | `0x0082d3b6` | |
| `0x18` | displayClock | `0x0082ccb6` | `0x68b6` | `0x0082d3de` | |
| `0x1e` | realTimeHeartRate | `0x0082d20c` | `0x6e0c` | `0x0082d3a0` | |
| `0x25` | setSitLong | `0x0082d284` | `0x6e84` | `0x0082d390` | |
| `0x26` | readSitLong | `0x0082d258` | `0x6e58` | `0x0082d398` | |
| `0x2b` | menstruation | `0x0082ba54` | `0x5654` | `0x0082d388` | |
| `0x2c` | bloodOxygenSetting | `0x0082d1c2` | `0x6dc2` | `0x0082d3a8` | |
| `0x37` | pressureHistory | `0x0082caa6` | `0x66a6` | `0x0082d40e` | |
| `0x38` | pressureSetting | `0x0082ca54` | `0x6654` | `0x0082d490` | |
| `0x39` | hrvHistory | `0x0082c9da` | `0x65da` | `0x0082d498` | |
| `0x3a` | sugarLipidsSetting | `0x0082cc1e` | `0x681e` | `0x0082d3e6` | |
| `0x3b` | uvSetting | `0x0082cbc8` | `0x67c8` | `0x0082d3ee` | |
| `0x43` | readDetailSport | `0x0082d034` | `0x6c34` | `0x0082d3ae` | |
| `0x72` | pushMsgUint | `0x00829e92` | `0x3a92` | `0x0082d378` | |
| `0x77` | phoneSport | `0x0082ce0c` | `0x6a0c` | `0x0082d3be` | |
| `0x7a` | muslim | `0x0082cb3a` | `0x673a` | `0x0082d3f6` | |
| `0x7d` | *(noop)* | — | — | advance | explicit deferred no-op |
| `0x81` | config chunk | `0x0082cdac` | `0x69ac` | `0x0082d3ce` | payload from `frame+1` |
| `0xa1` | factory/test | `0x00827f5c` | `0x1b5c` | `0x0082d4a0` | |
| `0xc6` | restoreKey | inline | — | `0x0082d460` | sub `0x6c` reboot path |
| `0xc7` | vibe/motor | `0x00832ebc` | `0xcabc` | `0x0082d4a8` | payload from `frame+1` |
| `0xff` | factory reset | `0x0082cde8` | `0x69e8` | `0x0082d3c6` | magic `0x66` checks |

### Compare tree order (binary search)

Root `cmp r1, #0x38` then left/right cascade — full listing in
`ch-a-dispatch-audit/evidence.md` §5 and `protocol-complete/evidence.md` §6.

### §10.2 gap check

| Opcode in tree | In PROTOCOL deferred inventory? |
|---:|---|
| all active above | **yes** (names/addresses already documented) |
| `0x14`, `0x7d` noops | documented as intentional absence / no-op |
| **none missing** | — |

---

## B. Immediate vendor/high path (`0x0082c5f6`)

### B.1 Low switch8 (`0x0082c61c`, max `0x27`)

| Op | Target even | Callee | Behavior |
|---:|---:|---:|---|
| `0x01,06,08,0e,15,18,1e,25,26` | `0x0082c662` | enqueue deferred `0x0082be64` | ring copy |
| `0x02` | `0x0082c788` | `0x0082c4d4` | camera |
| `0x03` | `0x0082c7b2` | `0x0082bc7e` | battery |
| `0x04` | `0x0082c7ba` | `0x0082c432` | bind |
| `0x0a` | `0x0082c79c` | `0x0082b9c6` | settings |
| `0x0c` | `0x0082c7e2` | `0x0082c0de` | BP setting |
| `0x0d` | `0x0082c7fa` | prep+send | BP history |
| `0x10` | `0x0082c794` | `0x0082b9a8` | short alert |
| `0x14` | `0x0082c752` | — | true no-op |
| `0x16` | `0x0082c7d2` | `0x0082c164` | HR setting |
| `0x19` | `0x0082c7a4` | `0x0082c484` | degree |
| `0x21` | `0x0082c804` | `0x0082bfd8` | targets |
| default / gaps | `0x0082c74e` | `0x0082bcba` | vendor NAK |

### B.2 High switch8 `0x97..0xa0` (`0x0082c6e0`)

| Op | Callee | Response |
|---:|---:|---|
| `0x97` | `0x00827ba4` | none |
| `0x98` | `0x00827be6` | self-marker mode1 |
| `0x99` | `0x00827bea` | none |
| `0x9a` | `0x00827bec` | self-marker mode2 |
| `0x9b` | `0x00827bf0` | status byte |
| `0x9c` | `0x00827c1e` | self-marker + stop |
| `0x9d` | `0x0082bcba` | NAK `[op\|80, ee]` |
| `0x9e` | `0x00827cc8` | model string |
| `0x9f` | `0x00827b16` | none |
| `0xa0` | `0x00827d1a` | 9 status bytes |
| default | NAK | |

### B.3 High cascade (outside switch)

| Op | Site | Callee | Notes |
|---:|---:|---:|---|
| `0x90` | `0x0082c83e` | `0x00827ad2` | self-marker |
| `0x91` | `0x0082c846` | `0x00827aee` | checksum ACK |
| `0x92` | `0x0082c84e` | `0x00827b14` | none |
| `0x93` | `0x0082c856` | `0x00827c4a` | FW string |
| `0x94` | `0x0082c85e` | `0x00827b2e` | mode1 |
| `0x95` | `0x0082c866` | `0x00827b54` | mode3 |
| `0x96` | `0x0082c86e` | `0x00827b7c` | mode4 |
| `0xbf` | `0x0082c8be` | `0x0082ba94` | mem write |
| `0xc0` | `0x0082c8c6` | `0x0082bb0c` | mem read |
| `0xc1` | `0x0082c8ce` | streamer | health poll 1B |
| `0xc3` | `0x0082c8e0` | OTA SM | control |
| `0xcd` | `0x0082c934` | `0x0082be12` | small mem read |
| `0xce` | `0x0082c93c` | `0x0082bcde` | factory/test |
| `0xfe` | `0x0082c75e` | `0x00844214` | synthetic sleep, no rsp |

Also special-cased before switch: `0x43`, `0x48` skip OTA abort; unknown → NAK.

---

## C. Channel-B inventory (summary)

### C.1 First-stage special

| cmd | Route |
|---:|---|
| `0x01,02,21,31,35,36,61` | pre-store `ota_dfu_state_machine(1,0)` then async store |
| `0x10,0x46` | cleanup / bypass async |
| other CRC-OK | async store |

### C.2 Async low OTA switch

| cmd | Handler body | Role |
|---:|---:|---|
| `0x01` | `0x8da4` | start |
| `0x02` | `0x8db6` | init meta |
| `0x03` | `0x8e40` | data |
| `0x04` | `0x8f78` | check |
| `0x05` | `0x8fb4` | end |
| `0x07` | `0x9010` | sub-ack |
| else | NAK 0 | |

### C.3 Async cascade (selected)

| cmd | Behavior |
|---:|---|
| `0x11` | sleep summary |
| `0x12` | detailed sleep |
| `0x13,0x29,0x3b` | no-response placeholders |
| `0x21..0x24` | NAK code **2** |
| `0x27` | sleep records (+ optional `0x3e` nap rsp) |
| `0x2a` | activity summary |
| `0x2c` | alarm r/w |
| `0x41,0x43` | file table / op |
| `0x46` | async branch dead for normal on-wire |
| `0x47,0x4b` | `bx lr` placeholders |
| `0x5a` | device-info TLV |
| other | NAK code **0** |

---

## D. File-table fieldId constants

| fieldId | Width | Record offset |
|---:|---:|---:|
| `0x01` | 4 | `+0x00` |
| `0x02` | 2 | `+0x12` |
| `0x03` | 2 | `+0x14` |
| `0x04` | 4 | `+0x1c` |
| `0x05` | 2 | `+0x16` |
| `0x06` | 2 | `+0x18` |
| `0x07` | 1 | `+0x07` |
| `0x08` | 1 | `+0x08` |
| `0x09` | 1 | `+0x09` |
| `0x0d` | 1 | `+0x0a` |
| `0x13` | 4 | `+0x2c` |

Sets: extended `{1..9,0xd,0x13}` for recordType 4/7/8; default `{1,2,4,7,8,9}`.

---

## E. `0xa0` status frame map

| Byte | Source helper / RAM | Static role |
|---:|---|---|
| 0 | const `0xa0` | opcode |
| 1 | `*(u8*)0x209dd0` | live flag |
| 2 | mode-class helper → `0x23` or 0 | active mode marker |
| 3 | secondary helper → `0x21` or 0 | secondary active marker |
| 4 | battery % clamp 100 | battery |
| 5–6 | `s16` at `0x209dbc+6` BE-split | raw channel |
| 7 | `*(u8*)(0x2088fc+0x50)` | blob0 byte |
| 8–9 | `u16` at `0x2088fc+0x42` | blob0 halfword |
| 15 | additive cksum | |

---

## F. OTA state / NAK quick table

| State | Meaning |
|---:|---|
| 0 | idle |
| 1 | started |
| 2 | meta accepted |
| 3 | data in progress |
| 4 | length verified |
| 5 | end/apply |

| NAK/status code | Meaning |
|---:|---|
| 0 | unknown cmd / OK depending on type |
| 1 | param/length/magic error (context) |
| 2 | CRC fail or explicit reject `0x21..24` / init type |
| 3 | wrong OTA state |
| 6 | low battery (RSP type) |

---

## G. `qc_app_task` tick (flash)

| Order | Flash | Role |
|---:|---:|---|
| 1 | `0x0082d2dc` | Channel-A deferred drain |
| 2 | `0x0083304c` | secondary notify/ring |
| 3 | `0x0082fc0c` | Channel-B async |
| 4 | `0x00827134` | timer/RTC work |
| 5 | `0x00829156` | live-status worker |
| 6–9 | `0x00837cbc` … `0x00837d5e` | UI/sensor ticks |

---

## H. Live-capture-only checklist

1. ECG/PPG notify opcodes (none in v14 static)  
2. `0xa0` human labels for flags + s16 channel  
3. BP compact ↔ cuff mmHg  
4. Cloud `@RequiresSignature` set  
5. `image_digest` algo (bootloader)  
6. File fieldId product names  
7. BP setting 7-byte field meanings  
8. Sleep detail slot units  
