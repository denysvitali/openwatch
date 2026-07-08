# Vendor/High Dispatcher Audit — H59MA v14

Scope: `firmwares/_re/v14/body.bin`  
Base mapping (canonical): **flash = body_offset + `0x00826400`**  
r2: `r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826400`

Do **not** map the OTA container at `0x00826000` (+`0x50` illusion).

---

## Summary

| Item | Result | Confidence |
|---|---|---|
| Channel-A write → 16-byte vendor/high path | `channel_a_gatt_write_handler` `0x0082e87a` event `2` → guard `0x0082c944` | **High** |
| Guard: `len==16` + service-suspend | `*DAT_0082caec == 1` early-out; `r1 != 0x10` early-out | **High** |
| Real dispatcher body | `0x0082c5f6` (body `0x61f6`) | **High** |
| Guard stub | `0x0082c944` (body `0x6544`) | **High** |
| Claimed “guard” `0x0082c994` | Interior of fragmenter `0x0082c988` — **not** guard | **High** |
| Claimed “real” `0x0082c646` | Mid-tree of low-range compares — **not** prologue | **High** |
| High switch8 `0x97..0xa0` | Table at `0x0082c6e0` (body `0x62e0`) | **High** |
| **`0x9d`** | **Vendor NAK** via `fee7_send_vendor_nak` (`0x0082bcba`) — **not** HighNoResponse | **High** |
| ECG/PPG | No `ECG`/`ecg`/`PPG`/`ppg` strings; mode `0x07` absent in `0x69` start; no dedicated notify opcode | **High** |

### Prior claim re-check

| Prior claim | Verdict |
|---|---|
| Guard `0x0082c994` → real `0x0082c646`; old `0x0082c944` is interior OTA | **Rejected.** Guard is `0x0082c944`; body is `0x0082c5f6`; `0x0082c994` is fragmenter loop; OTA control is `0xc3` at `0x0082c8e0`. |
| Low switch `0x0082c66c`, high `0x0082c730` | **Rejected as table bases.** Low `switch8` table is at `0x0082c61c`; high at `0x0082c6e0`. Those addresses sit *inside* the binary-tree compare cascade, not the tables. |
| `0x9d` is vendor NAK `[opcode\|0x80, 0xee]` | **Confirmed.** |
| ECG/PPG absent on v14 | **Confirmed.** |

---

## 1. Channel-A write path (feeds 16-byte vendor/high)

### Commands

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826400 \
  -c 'pd 40 @ 0x0082e87a; pd 20 @ 0x0082c944; pd 20 @ 0x0082c5f6; pd 20 @ 0x0082ea4c' \
  firmwares/_re/v14/body.bin
```

### Write handler (`0x0082e87a`, body `0x847a`)

GATT event type `2` (write) branches to the guard:

```text
0x0082e888  cmp r2, 2
0x0082e88a  beq 0x82e8b6
...
0x0082e8b6  bl 0x82c944          ; vendor/high guard
0x0082e8ba  b 0x82e8ca
```

`fee7_gatt_write_handler` (`0x0082ea4c`) packages Realtek service events and **does not** call the 16-byte dispatcher (reconfirmed).

### Guard stub (`0x0082c944`, body `0x6544`)

```text
0x0082c944  ldr r2, [0x0082caec]   ; DAT → 0x208d30
0x0082c946  ldrb r2, [r2]
0x0082c948  cmp r2, 1              ; service-suspended flag
0x0082c94a  beq 0x82c952           ; return
0x0082c94c  cmp r1, 0x10           ; length == 16
0x0082c94e  bne 0x82c952           ; return
0x0082c950  b 0x82c5f6             ; real body (r0 = frame ptr)
0x0082c952  bx lr
```

### Real body prologue (`0x0082c5f6`, body `0x61f6`)

```text
0x0082c5f6  push {r4, lr}
0x0082c5f8  mov r4, r0
0x0082c5fa  ldrb r0, [r0]          ; opcode
0x0082c5fc  cmp r0, 0x43           ; 'C'
0x0082c5fe  beq 0x82c608
0x0082c600  cmp r0, 0x48           ; 'H'
0x0082c602  beq 0x82c608
0x0082c604  bl 0x82eebe            ; abort active OTA before vendor cmd
0x0082c608  ldrb r0, [r4]
0x0082c60a  cmp r0, 0x7a           ; start of binary-tree dispatch
...
```

GHIDRA’s pseudo-C for `fee7_dispatch_vendor_command` merges guard + body into one logical function; statically they are two sites linked by `b 0x82c5f6`.

---

## 2. Three addresses: body vs guard vs interior

| Role | Flash | Body | Notes |
|---|---:|---:|---|
| **Real dispatcher body** | `0x0082c5f6` | `0x61f6` | `push {r4,lr}` + opcode load + OTA abort + switch tree |
| **Guard stub** | `0x0082c944` | `0x6544` | Suspend flag + `len==16`; sole static call from write handler |
| **Fragmenter (misread as guard)** | `0x0082c988` / interior `0x0082c994` | `0x6588` / `0x6594` | Chunks long payloads into 13-byte slices + checksum + `channel_a_queue_notify_frame` |
| Mid-tree (misread as “real”) | `0x0082c646` | `0x6246` | `cmp r0, 0x43` node after `bgt` from low range |
| OTA control handler (interior of body) | `0x0082c8e0` | `0x64e0` | Opcode `0xc3` → service reset + `ota_dfu_state_machine` |

### Fragmenter at `0x0082c994` (why prior “guard” claim failed)

```text
0x0082c988  push {r0,r1,r2,r4,r5,r6,r7,lr}
...
0x0082c994  b 0x82c9d2            ; loop header (not an entry)
0x0082c996  ... build 16-byte chunk ...
0x0082c9ae  cmp r2, 0xd
0x0082c9cc  bl 0x82ebdc           ; queue notify
0x0082c9d2  cmp r4, r6
0x0082c9d4  blt 0x82c996
```

This is **response fragmentation**, not the write-side guard.

---

## 3. Switch tables

### Switch8 helper (`0x008405fc`)

```text
0x008405fc  push {r4, r5}
0x008405fe  mov r4, lr
0x00840600  subs r4, r4, 1       ; table = LR & ~1
0x00840602  ldrb r5, [r4]        ; max index
0x00840604  adds r4, r4, 1       ; offsets base
0x00840606  cmp r3, r5
0x00840608  bhs 0x84060c         ; index >= max → use max (default slot)
0x0084060a  mov r5, r3
0x0084060c  ldrb r3, [r4, r5]
0x0084060e  lsls r3, r3, 1
0x00840610  adds r3, r4, r3      ; target = offsets_base + 2*offset
0x00840612  pop {r4, r5}
0x00840614  bx r3
```

Decode: `target_thumb = (table + 1) + 2 * offset_byte[index]`.

### Low-range switch8 — table `0x0082c61c` (body `0x621c`)

Entered when opcode `< 0x2b` (after tree). Max index byte `0x27`.

| Opcode | Target (Thumb) | Even insn | Behavior (static) |
|---:|---:|---:|---|
| many gaps | `0x0082c74f` | `0x0082c74e` | **Vendor NAK** |
| `0x01`,`0x06`,`0x08`,`0x0e`,`0x15`,`0x18`,`0x1e`,`0x25`,`0x26` | `0x0082c663` | `0x0082c662` | Deferred ring (`b 0x82c92c` → `FUN_0082be64`) |
| `0x02` | `0x0082c789` | `0x0082c788` | handler thunk |
| `0x03` | `0x0082c7b3` | `0x0082c7b2` | battery-ish |
| `0x04` | `0x0082c7bb` | `0x0082c7ba` | bind/ANCS |
| `0x0a` | `0x0082c79d` | `0x0082c79c` | setting |
| `0x0c` | `0x0082c7e3` | `0x0082c7e2` | BP setting |
| `0x0d` | `0x0082c7fb` | `0x0082c7fa` | BP history path |
| `0x10` | `0x0082c795` | `0x0082c794` | short alert |
| **`0x14`** | **`0x0082c753`** | **`0x0082c752`** | **True no-op** (`pop {r4,pc}` only) |
| `0x16` | `0x0082c7d3` | `0x0082c7d2` | HR setting |
| `0x19` | `0x0082c7a5` | `0x0082c7a4` | degree unit |
| `0x21` | `0x0082c805` | `0x0082c804` | daily target |

(Full per-slot dump: max=`0x27`; default slot offset `0x99` → NAK.)

### High-range switch8 — table `0x0082c6e0` (body `0x62e0`)

Raw: `0a cb cf d3 d7 db df 37 e3 eb e7 37`  
Max index `0x0a` (covers `0x97..0xa1`; slot `0xa1`/default → NAK).

| Op | Off | Target (Thumb) | Even | Callee / action |
|---:|---:|---:|---:|---|
| `0x97` | `0xcb` | `0x0082c877` | `0x0082c876` | `bl 0x827ba4` → **`bx lr`** (no response) |
| `0x98` | `0xcf` | `0x0082c87f` | `0x0082c87e` | `bl 0x827be6` session mode 1 + self-marker |
| `0x99` | `0xd3` | `0x0082c887` | `0x0082c886` | `bl 0x827bea` → **`bx lr`** (no response) |
| `0x9a` | `0xd7` | `0x0082c88f` | `0x0082c88e` | `bl 0x827bec` session mode 2 + self-marker |
| `0x9b` | `0xdb` | `0x0082c897` | `0x0082c896` | `bl 0x827bf0` status byte |
| `0x9c` | `0xdf` | `0x0082c89f` | `0x0082c89e` | `bl 0x827c1e` factory-stop self-marker |
| **`0x9d`** | **`0x37`** | **`0x0082c74f`** | **`0x0082c74e`** | **`bl 0x82bcba` vendor NAK** |
| `0x9e` | `0xe3` | `0x0082c8a7` | `0x0082c8a6` | `bl 0x827cc8` model name |
| `0x9f` | `0xeb` | `0x0082c8b7` | `0x0082c8b6` | `bl 0x827b16` → **`bx lr`** (no response) |
| `0xa0` | `0xe7` | `0x0082c8af` | `0x0082c8ae` | `bl 0x827d1a` high status |
| default/`0xa1` | `0x37` | `0x0082c74f` | `0x0082c74e` | same NAK |

### High range outside switch (`0x90..0x96`, `0xce`, `0xfe`, …)

Binary-tree / cascade (not switch8):

| Op | Flash site | Callee | Notes |
|---:|---:|---:|---|
| `0x90` | `0x0082c83e` | `0x00827ad2` | self-marker `[0x90,…,0x90]` |
| `0x91` | `0x0082c846` | `0x00827aee` | checksum ACK |
| `0x92` | `0x0082c84e` | `0x00827b14` | `bx lr` no-op |
| `0x93` | `0x0082c856` | `0x00827c4a` | FW version/build |
| `0x94` | `0x0082c85e` | `0x00827b2e` | test mode 1 |
| `0x95` | `0x0082c866` | `0x00827b54` | test mode 3 |
| `0x96` | `0x0082c86e` | `0x00827b7c` | test mode 4 |
| `0xbf` | `0x0082c8be` | `0x0082ba94` | mem write |
| `0xc0` | `0x0082c8c6` | `0x0082bb0c` | mem read |
| `0xc1` | `0x0082c8ce` | streamer | health poll 1 byte |
| `0xc3` | `0x0082c8e0` | OTA SM | service reset + DFU control |
| `0xcd` | `0x0082c934` | `0x0082be12` | small mem read |
| **`0xce`** | **`0x0082c93c`** | **`0x0082bcde`** | factory/test |
| **`0xfe`** | **`0x0082c75e`** | **`0x00844214`** | synthetic sleep (no response) |
| unknown | `0x0082c74e` | `0x0082bcba` | vendor NAK |

---

## 4. Prove `0x9d` = vendor NAK (not HighNoResponse)

### Commands

```sh
# high table bytes
r2 ... -c 'px 16 @ 0x0082c6e0' firmwares/_re/v14/body.bin
# helper + default/NAK site + NAK builder
r2 ... -c 'pd 15 @ 0x008405fc; pd 6 @ 0x0082c74e; pd 20 @ 0x0082bcba' \
  firmwares/_re/v14/body.bin
```

### Arithmetic

- Index for `0x9d`: `0x9d - 0x97 = 6`
- Offset byte: table `[0x0082c6e0+1+6] = 0x37`
- Target: `(0x0082c6e0 + 1) + 2*0x37 = 0x0082c6e1 + 0x6e = 0x0082c74f` (Thumb)

### Disassembly at target

```text
0x0082c74e  bl 0x82bcba          ; fee7_send_vendor_nak
0x0082c752  pop {r4, pc}         ; epilogue (also pure no-op target for 0x14 etc.)
```

### NAK builder (`0x0082bcba`, body `0x58ba`)

```text
0x0082bcba  push {r0,r1,r2,r3,r4,lr}
...
0x0082bcc6  movs r1, 0x80
0x0082bcc8  orrs r0, r1          ; response opcode = req_opcode | 0x80
0x0082bcca  mov r2, sp
0x0082bccc  strb r0, [r2]        ; frame[0]
0x0082bcce  movs r1, 0xee
0x0082bcd0  strb r1, [r2, 1]     ; frame[1] = 0xee
0x0082bcd2  adds r0, 0xee
0x0082bcd4  strb r0, [r2, 0xf]   ; frame[15] checksum-ish
0x0082bcd6  mov r0, sp
0x0082bcd8  bl 0x82ebdc          ; channel_a_queue_notify_frame
```

Wire shape for `0x9d`: **`[0x1d, 0xee, 0, …, cksum]`** where `0x1d = 0x9d | 0x80`.

### Why `fee7-high/evidence.md` said “no response”

That pass mapped `0x9d` → body `0x6352` (`pop {r4,pc}` only). That is the **instruction after** the NAK `bl`, i.e. the shared epilogue. Off-by-one in switch decode (`table+2+2*off` vs `(table+1)+2*off`) lands one halfword early/late and confuses NAK site with pure return.

Contrast true no-response high slots:

```text
0x00827ba4  bx lr    ; 0x97
0x00827bea  bx lr    ; 0x99
0x00827b16  bx lr    ; 0x9f
```

---

## 5. ECG / PPG negative evidence

### 5.1 Strings

```sh
python3 - <<'PY'
from pathlib import Path
b = Path('firmwares/_re/v14/body.bin').read_bytes()
for p in [b'ECG', b'ecg', b'Ecg', b'PPG', b'ppg', b'Ppg']:
    print(p, b.count(p))
PY
```

Result: **all counts 0**.  
(`strings | rg -i ppg` hits are Thumb garbage containing `ppG` as bytes, not C strings. Real related string: `spo2_VC30F_S_int_limit_ed01`, `m_heart_rate_timer_id`.)

### 5.2 Health start `0x69` — mode `0x07` fallthrough

Handler: `health_handle_start_measure` flash `0x0082c2f4` (body `0x5ef4`).

```text
0x0082c360  cmp r0, 3     ; mode 0x03
0x0082c364  cmp r0, 9     ; mode 0x09
0x0082c368  cmp r0, 0x0b  ; mode 0x0B
0x0082c36c  cmp r0, 0x0d  ; mode 0x0D
0x0082c370  cmp r0, 0x0e  ; mode 0x0E
0x0082c374  cmp r0, 0x0c  ; mode 0x0C
0x0082c378  b 0x82c3c6    ; default → movs r0, 1 ; health_post...
...
; mode 6 handled on earlier branch (0x82c33c / 0x82c3ce sub-machine)
```

No `cmp r0, #7` in the start-handler region (byte search `0728` count **0** in body `0x5ef4..0x60f4`).  
Mode `0x07` (APK ECG type) → **fallthrough to generic HR mode-1 path**.

### 5.3 Notify builders

- Live health notify uses opcode **`0x69`** only (timer path body `0x4e98` / flash `0x0082b298` region — see `health-measure/evidence.md`).
- SpO2 auto-measure control is **`0x2c`** (cadence, not real-time PPG stream).
- High-range `0x97..0xa0` responses: session ACK/status, model string, opaque status — **no** ECG/PPG multi-sample shapes.

---

## 6. Doc cross-check / contradictions

| Doc | Claim | This audit |
|---|---|---|
| `PROTOCOL.md` §4.5 `HighNoResponse` | includes **`0x9d`** with body `0x6352` | **Wrong for `0x9d`** — NAK at body `0x634e` |
| `GHIDRA_DECOMPILATION.md` §8.1 high table | `0x9d` “Dispatcher return; no response” | **Wrong** |
| `GHIDRA_DECOMPILATION.md` §8.20 | same | **Wrong** |
| `firmwares/_re/fee7-high/evidence.md` | `0x9d` → `0x6352` no response | **Wrong** (off-by-one switch decode) |
| `fee7-high` on `0x97/99/9f` no-response | correct | **Agree** |
| `fee7-high` on `0x98/9a/9b/9c/9e/a0` real handlers | correct | **Agree** |
| `GHIDRA` §8: write path = Channel-A `0x0082e87a`, not FEE7 GATT | correct | **Agree** |
| `GHIDRA` pseudo-C merges guard+body at `FUN_0082c944` | OK as logical model | Split: guard `0x82c944`, body `0x82c5f6` |
| Prior address claim (guard `0x82c994`) | — | **Wrong** (fragmenter) |
| `health-measure/evidence.md` ECG mode `0x07` fallthrough | correct | **Agree** |
| `health-measure` live notify `0x69` | correct | **Agree** |

Naming note: many symbols still say `fee7_*` but the **static GATT entry** for this 16-byte dispatcher is Channel-A (`6e40fff0`). FEE7 (`0xFEE7`) write path does not reach it.

---

## 7. Doc-change recommendations

### High confidence (do now)

1. **`PROTOCOL.md`**: remove `0x9d` from `HighNoResponse`; document as vendor NAK (`[0x9d|0x80, 0xee, …]`). Keep `0x97` / `0x99` / `0x9f` as no-response.
2. **`GHIDRA_DECOMPILATION.md` §8.1 / §8.20**: change `0x9d` row from “no response” to `fee7_send_vendor_nak`.
3. Optional one-liner on addresses: guard `0x0082c944`, body `0x0082c5f6` (avoid citing `0x0082c994` as entry).

### Prefer evidence-only (large rewrites)

- Full low/high switch address tables already expanded here; do not mass-rewrite GHIDRA §8 unless doing a dedicated pass.
- Annotate `fee7-high/evidence.md` as superseded for `0x9d` only.

### Leave open

- Semantic names for `0x69` modes `0x03/09/0B/0C/0D/0E` still need live capture.
- Opaque `0xa0` status field meanings.

---

## 8. Confidence

| Finding | Confidence |
|---|---|
| Write path + len16 + suspend flag | High |
| Guard / body / fragmenter split | High |
| High switch decode incl. `0x9d` → NAK | High |
| `0x97/99/9f` true no-response | High |
| `0xce` factory, `0xfe` synthetic sleep | High |
| ECG/PPG absence (strings + mode 0x07 + no notify) | High |
| Full low-range handler naming | Medium (slots decoded; names from prior docs) |

---

## Address cheat sheet

| Symbol-ish | Flash | Body |
|---|---:|---:|
| `channel_a_gatt_write_handler` | `0x0082e87a` | `0x847a` |
| vendor/high **guard** | `0x0082c944` | `0x6544` |
| vendor/high **body** | `0x0082c5f6` | `0x61f6` |
| low switch8 table | `0x0082c61c` | `0x621c` |
| high switch8 table | `0x0082c6e0` | `0x62e0` |
| default / `0x9d` NAK call | `0x0082c74e` | `0x634e` |
| dispatcher epilogue / true no-op | `0x0082c752` | `0x6352` |
| `fee7_send_vendor_nak` | `0x0082bcba` | `0x58ba` |
| fragmenter | `0x0082c988` | `0x6588` |
| health start `0x69` | `0x0082c2f4` | `0x5ef4` |
| switch8 helper | `0x008405fc` | (high body region) |
