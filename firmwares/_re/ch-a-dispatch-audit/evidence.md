# Channel-A Deferred Dispatcher Address Audit

Date: 2026-07-08

Scope: H59MA v14 OTA body only — `firmwares/_re/v14/body.bin`.

## Summary + confidence

| Claim | Result |
|---|---|
| Documented `channel_a_dispatch_queued_frame` at flash `0x0082d2dc` (body `0x6edc`) | **Valid Thumb function entry** |
| Reverted claim: real entry is `0x0082d32c` (doc + `0x50`) | **False** — mid-function opcode-tree site, zero callers |
| Documented per-opcode handler addresses | **Correct** — each is a `push {…, lr}` prologue and is the sole BL target from the drain loop |
| Documented + `0x50` handler addresses | **Garbage / mid-function** — not prologues |
| `qc_app_task` calls which dispatcher? | Only **`bl 0x0082d2dc`** (from `0x008272c0`) |

**Confidence: HIGH.**

**Verdict:** The +`0x50` claim was **not** a real systematic address-base error in the saved docs. It was an artifact of treating a mid-function address as a function entry (and/or shifting addresses by an arbitrary `0x50`). Documented addresses in `GHIDRA_DECOMPILATION.md` §0.1 / §3 and `PROTOCOL.md` stay correct. **No doc address rewrites required.**

### Why +`0x50` is not container-vs-body remapping

Canonical mapping:

| Mapping | Base | body offset 0 → |
|---|---|---|
| Correct (this audit + Ghidra project) | `0x00826400` | flash `0x00826400` |
| Wrong: map `body.bin` at container base | `0x00826000` | flash `0x00826000` |

Delta between container flash base (`header.flash_base` = `0x00826000`) and app body load (`header.flash_app_start` = `0x00826400`) is **`0x400`**, not `0x50`.

If `body.bin` were wrongly mapped at `0x00826000`, the documented dispatcher body offset `0x6edc` would be labeled `0x0082cedc` — **`0x400` low**, not `0x50` low.

The address `0x0082d32c` is exactly **`0x50` bytes into** the real function at `0x0082d2dc`. That lands on the `beq` of the `cmp r1, #0x2c` arm inside the binary-search opcode tree — a plausible place for a naive auto-analyzer or a mis-clicked "function start," but not a real entry and not a base remap.

---

## Canonical address convention (used here)

```
Work file:  firmwares/_re/v14/body.bin
App load:   0x00826400   (body offset 0 → flash 0x00826400)
body_off = flash_addr - 0x00826400
```

Do **not** map the container `.bin` at `0x00826000` for conclusions.

---

## Commands used (reproducible)

```sh
# Mapped disassembly (canonical)
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -m 0x00826400 firmwares/_re/v14/body.bin

# Inside r2:
#   pd 120 @ 0x0082d2dc          # documented dispatcher
#   pd 40  @ 0x0082d32c          # +0x50 candidate
#   pd 80  @ 0x0082724c          # qc_app_task body (entry from task create)
#   pd 12  @ <handler>           # documented handlers
#   pd 12  @ <handler+0x50>      # shifted handlers
#   pd 30  @ 0x0082d4ac          # ring advance / exit

# Body-offset verification (no -m)
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  firmwares/_re/v14/body.bin
#   pd 20 @ 0x6edc
#   pd 20 @ 0x6f2c
#   pd 60 @ 0x0ec0   # BL site inside task (flash 0x8272c0)
```

Python BL xref scan (Thumb long-BL decoder over the whole body):

- Exactly **one** BL targets `0x0082d2dc` → from `0x008272c0` (body `0x0ec0`) inside `qc_app_task`.
- **Zero** BLs target `0x0082d32c`.
- Each sample handler below has exactly one BL, all from inside the documented drain loop.

---

## Task 1 — Documented dispatcher `0x0082d2dc` (body `0x6edc`)

**Valid Thumb function.** Classic prologue, loads ring state, jumps to empty-check, then drains.

```text
0x0082d2dc  push {r4, r5, r6, lr}
0x0082d2de  ldr  r5, [0x0082d440]     ; → RAM 0x00209f40
0x0082d2e0  adds r5, #0x14            ; r5 → head/tail at 0x00209f54
0x0082d2e2  b    0x0082d4c2           ; jump to empty-check / loop head
0x0082d2e4  lsls r0, r0, #4           ; index * 16  (loop body entry)
0x0082d2e6  adds r4, r0, r5
0x0082d2e8  ldrb r1, [r4, #4]         ; opcode = frame[0]
0x0082d2ea  adds r4, r4, #4           ; r4 = &frame[0]
0x0082d2ec  cmp  r1, #0x38            ; binary-search tree root
…
```

Same bytes at body offset `0x6edc` without `-m`: `70 b5 58 4d 14 35 ee e0 …`.

---

## Task 2 — Candidate `0x0082d32c` (body `0x6f2c`)

**Not a function.** Mid-tree branch of the same dispatcher:

```text
0x0082d32a  cmp  r1, #0x2c            ; still inside 0x0082d2dc
0x0082d32c  beq  0x0082d3a6           ; ← "candidate entry" is this beq
0x0082d32e  cmp  r1, #0x37
0x0082d330  bne  0x0082d37c
…
```

No push prologue, no independent stack frame, no BL xrefs. Treating this as entry would desync Thumb decode for anything that assumed a new function boundary.

---

## Task 3 — Callers from `qc_app_task`

Task create site (string `"qc_app"`, entry literal `0x0082724d` → Thumb entry `0x0082724c`):

```text
0x0082731e  ldr  r2, [0x00827344]     ; = 0x0082724d (qc_app_task entry|1)
0x00827320  adr  r1, "qc_app"
0x00827324  bl   <os_task_create>
```

Main loop body (`FUN_0082724c` / `qc_app_task`):

```text
0x008272b4  mov  r1, r5               ; timeout = -1
0x008272b6  ldr  r0, [r4, #4]         ; message queue
0x008272b8  bl   <os_message_get>
0x008272bc  cmp  r0, #0
0x008272be  beq  0x008272b4
0x008272c0  bl   0x0082d2dc           ; channel_a_dispatch_queued_frame  ← ONLY
0x008272c4  bl   0x0083304c
0x008272c8  bl   0x0082fc0c           ; channel_b_async_command_processor
…
0x008272e4  b    0x008272b4
```

| Target | BL count (whole body.bin) | From |
|---|---:|---|
| `0x0082d2dc` | 1 | `0x008272c0` |
| `0x0082d32c` | 0 | — |

Note: flash `0x00827310` is **not** the task body — it sits in the task-*create* helper after the entry pointer setup. The live worker is `0x0082724c`.

---

## Task 4 — Sample opcodes: documented vs documented+`0x50`

| Opcode | Name | Doc flash | Doc body | Doc prologue | Doc+`0x50` | +`0x50` prologue? | BL from drain? |
|---|---|---|---|---|---|---|---|
| `0x01` | `setTime` | `0x0082bb4e` | `0x574e` | `push {r4-r7,lr}` (`f0b5`) | `0x0082bb9e` | **no** (`invalid` / mid-fn) | yes → doc |
| `0x0e` | `bpReadConform` | `0x0082cb28` | `0x6728` | `push {r4,lr}` (`10b5`) | `0x0082cb78` | **no** (`strb` mid-fn) | yes → doc |
| `0x15` | `readHeartRate` | `0x0082cf48` | `0x6b48` | `push {r4-r7,lr}` (`f0b5`) | `0x0082cf98` | **no** (`strb` mid-fn) | yes → doc |
| `0x72` | `pushMsgUint` | `0x00829e92` | `0x3a92` | `push {r1-r7,lr}` (`feb5`) | `0x00829ee2` | **no** (`bge` mid-fn) | yes → doc |
| `0xff` | factory reset | `0x0082cde8` | `0x69e8` | `push {r4,lr}` (`10b5`) | `0x0082ce38` | **no** (`invalid`) | yes → doc |

### Excerpts

**`0x01` setTime @ doc:**

```text
0x0082bb4e  push {r4, r5, r6, r7, lr}
0x0082bb50  sub  sp, #0x1c
0x0082bb52  mov  r4, r0
0x0082bb54  bl   0x0082df12
…
0x0082bb62  movs r0, #0x2f            ; packet-length notify path
```

**`0x0e` bpReadConform @ doc:**

```text
0x0082cb28  push {r4, lr}
0x0082cb2a  ldrb r0, [r0, #1]
0x0082cb2c  cmp  r0, #0
0x0082cb2e  bne  0x0082cb38
0x0082cb30  bl   0x00834410
0x0082cb34  bl   0x0082c0a4
```

**`0xff` factory reset @ doc (magic `0x66` checks):**

```text
0x0082cde8  push {r4, lr}
0x0082cdea  mov  r4, r0
0x0082cdec  ldrb r0, [r0, #1]
0x0082cdee  cmp  r0, #0x66
0x0082cdf0  bne  0x0082ce0a
0x0082cdf2  ldrb r0, [r4, #2]
0x0082cdf4  cmp  r0, #0x66
…
```

Full handler-table prologue sweep (all deferred BL targets listed in §5): **every documented address is `push {…lr}` (`0xb5xx`); every documented+`0x50` is not.**

---

## Task 5 — Deferred ring drain loop map

### State

| Item | Address / value |
|---|---|
| Literal pool word (loaded by dispatcher) | flash `0x0082d440` → RAM `0x00209f40` |
| After `adds r5, #0x14` | `r5 = 0x00209f54` = head/tail + frame base (same object as `DAT_0082bfcc` / deferred ring) |
| Head halfword | `[r5 + 0]` |
| Tail halfword | `[r5 + 2]` |
| Frame `i` | `r5 + 4 + i*0x10` (opcode at byte 0 of frame) |
| Slot count | 10 (`head` wraps when `>= 9` then set 0, else `+1`) |

### Loop shape

```text
entry:
  push {r4,r5,r6,lr}
  r5 = *0x82d440 + 0x14
  goto empty_check

loop_body:                         ; 0x0082d2e4
  r4 = &frames[head]
  r1 = opcode = frame[0]
  r4 = &frame[0]
  binary-search cmp tree on r1
  matched arm:  mov r0, r4 ; bl handler ; b advance
  unmatched / 0x7d:                 fall to advance (no handler, no response)

advance:                           ; 0x0082d4ac
  head = (head >= 9) ? 0 : head+1
  store head
empty_check:                       ; 0x0082d4c2
  if head != tail: goto loop_body
  pop {r4,r5,r6,pc}
```

### Opcode compare tree (observed `cmp r1, #imm` order)

Root and children (not a table — compiler binary search):

```text
0x38 ─ eq → pressureSetting
     ─ gt → 0x7a / 0x43 / 0x39 / 0x3a / 0x3b / 0x72 / 0x77 / 0xc6 / 0x7d / 0x81 / 0xa1 / 0xc7 / 0xff
     ─ lt → 0x18 / 0x0e / 0x01 / 0x06 / 0x08 / 0x14(no-op path) / 0x15 / 0x2b / 0x1e / 0x25 / 0x26 / 0x2c / 0x37
```

Special cases (not simple `mov r0,r4; bl handler`):

| Opcode | Behavior |
|---|---|
| `0x08` | Inline sub-dispatch on `frame[1]` → camera/find helpers (`0x008275b6`, `0x00827516`, `0x008280fe`, `0x00827ba6`) |
| `0x14` | Compare present; equal path is queue-advance only (no handler BL) |
| `0x7d` | `beq` straight to advance — deferred no-op (matches `PROTOCOL.md` / GHIDRA notes) |
| `0x81` | `adds r0, r4, #1` then `bl 0x0082cdac` (payload starts at byte 1) |
| `0xc6` | Inline reboot/`restoreKey` sequence (`0x6c` sub-check, timers, `FUN_0082b986`) |
| `0xc7` | `adds r0, r4, #1` then `bl 0x00832ebc` |
| default | advance with no call |

### Opcode → correct handler address table

Addresses recovered from `bl` sites inside `0x0082d2dc..0x0082d4ac`. Body offset = flash − `0x00826400`.

| Opcode | Name | Handler flash | Handler body | Drain BL site |
|---|---|---|---|---|
| `0x01` | `setTime` | `0x0082bb4e` | `0x574e` | `0x0082d3fe` |
| `0x06` | `dnd` | `0x0082d298` | `0x6e98` | `0x0082d380` |
| `0x0e` | `bpReadConform` | `0x0082cb28` | `0x6728` | `0x0082d406` |
| `0x15` | `readHeartRate` | `0x0082cf48` | `0x6b48` | `0x0082d3b6` |
| `0x18` | `displayClock` | `0x0082ccb6` | `0x68b6` | `0x0082d3de` |
| `0x1e` | `realTimeHeartRate` | `0x0082d20c` | `0x6e0c` | `0x0082d3a0` |
| `0x25` | `setSitLong` | `0x0082d284` | `0x6e84` | `0x0082d390` |
| `0x26` | `readSitLong` | `0x0082d258` | `0x6e58` | `0x0082d398` |
| `0x2b` | `menstruation` | `0x0082ba54` | `0x5654` | `0x0082d388` |
| `0x2c` | `bloodOxygenSetting` | `0x0082d1c2` | `0x6dc2` | `0x0082d3a8` |
| `0x37` | `pressureHistory` | `0x0082caa6` | `0x66a6` | `0x0082d40e` |
| `0x38` | `pressureSetting` | `0x0082ca54` | `0x6654` | `0x0082d490` |
| `0x39` | `hrvHistory` | `0x0082c9da` | `0x65da` | `0x0082d498` |
| `0x3a` | `sugarLipidsSetting` | `0x0082cc1e` | `0x681e` | `0x0082d3e6` |
| `0x3b` | `uvSetting` | `0x0082cbc8` | `0x67c8` | `0x0082d3ee` |
| `0x43` | `readDetailSport` | `0x0082d034` | `0x6c34` | `0x0082d3ae` |
| `0x72` | `pushMsgUint` | `0x00829e92` | `0x3a92` | `0x0082d378` |
| `0x77` | `phoneSport` | `0x0082ce0c` | `0x6a0c` | `0x0082d3be` |
| `0x7a` | `muslim` | `0x0082cb3a` | `0x673a` | `0x0082d3f6` |
| `0x7d` | *(no-op)* | — | — | advance only (`0x6f5e`/`0x0082d35e` path) |
| `0x81` | config chunk | `0x0082cdac` | `0x69ac` | `0x0082d3ce` |
| `0xa1` | factory/test | `0x00827f5c` | `0x1b5c` | `0x0082d4a0` |
| `0xc6` | `restoreKey` | inline | — | inline @ `0x0082d460` |
| `0xc7` | vibe/motor | `0x00832ebc` | `0xcabc` | `0x0082d4a8` |
| `0xff` | factory reset | `0x0082cde8` | `0x69e8` | `0x0082d3c6` |

Dispatcher itself:

| Symbol | Flash | Body |
|---|---|---|
| `channel_a_dispatch_queued_frame` | `0x0082d2dc` | `0x6edc` |
| *(false +0x50 candidate)* | `0x0082d32c` | `0x6f2c` |
| `qc_app_task` | `0x0082724c` | `0x0e4c` |
| call site `bl dispatcher` | `0x008272c0` | `0x0ec0` |

All of the above **match** the existing tables in `firmwares/GHIDRA_DECOMPILATION.md` §3 (opcode → handler map) and the dispatcher symbol at `0x0082d2dc`.

---

## Verdict on the `0x50` claim

1. **Real dispatcher entry = `0x0082d2dc`.** Valid prologue, drained by `qc_app_task`, unique BL target.
2. **`0x0082d32c` is not an entry.** It is `+0x50` into the same function (the `0x2c`/`0x37` compare cluster). Zero xrefs.
3. **Handler addresses are not `0x50` low.** Documented addresses are the BL targets and have proper prologues; `+0x50` does not.
4. **Container `@0x00826000` vs body `@0x00826400` produces a `0x400` bias, not `0x50`.** So the reverted pass’s systematic +`0x50` cannot be explained as that base confusion alone. Most likely: mid-function address mistaken for entry (and possibly applied as a blanket shift).
5. **Docs should stay.** `GHIDRA_DECOMPILATION.md` and `PROTOCOL.md` already cite `0x0082d2dc` and the handler set above. Re-applying +`0x50` would break every xref.

### What docs should change

**None for addresses.** Optional future cross-link only: point readers of the dispatcher section at this evidence file if the +`0x50` claim reappears.

---

## File references

- Body image: [`firmwares/_re/v14/body.bin`](../v14/body.bin)
- Header (flash bases): [`firmwares/_re/v14/header.json`](../v14/header.json) — `flash_base=0x00826000`, `flash_app_start=0x00826400`
- Canonical writeup: [`firmwares/GHIDRA_DECOMPILATION.md`](../../GHIDRA_DECOMPILATION.md) §0.1, §3, §8.1
- Protocol surface: [`PROTOCOL.md`](../../../PROTOCOL.md) (dispatcher note ~`0x0082d2dc`)
