# Menstruation `periodData[8..12]` Consumers

Date: 2026-07-08

Scope: H59MA v14 body `firmwares/_re/v14/body.bin`. Body offsets unless noted.
Flash VA = body + **0x00826400**.

Tooling:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
```

Cross-refs: GHIDRA §3.1, PROTOCOL §4.3 `MenstruationReq`.

## Address verification

| Symbol (GHIDRA) | Flash VA | Body off | Status |
|---|---:|---:|---|
| `menstruation_config_update_from_frame` | `0x0082aee4` | `0x4ae4` | ✅ |
| `menstruation_config_encode_response` | `0x0082af28` | `0x4b28` | ✅ |
| `cycle_phase_detector` | `0x0082af64` | `0x4b64` | ✅ |
| `phase_window_fill` (multi-day) | `0x0082afae` | `0x4bae` | ✅ |
| `phase_transition_notifier` | `0x0082b01e` | `0x4c1e` | ✅ |
| `menstruation_config_init` | `0x0082b078` | `0x4c78` | ✅ |
| `phase_notify_fire` | `0x0082b090` | `0x4c90` | ✅ |
| `channel_a_handle_menstruation` | `0x0082ba54` | `0x5654` | ✅ |

RAM mixture base pointer literal: `0x208c7c` @ body `0x4cb8`.
Record base used in helpers: `0x208c7c - 0x20 = 0x208c5c`, with
`state_flag` at `base+0x1a` → **`0x208c76`**.

## Channel-A `0x2b` handler (`0x5654`)

```text
0x5654  push; zero 16 B stack frame
0x5660  rsp[0] = 0x2B
0x5666  sub = req[1]
        1 → bl 0x4b28 encode_response(rsp)
        2 → bl 0x4ae4 update_from_frame(req+2)
        else no-op
0x5680  cksum = additive sum first 15 B (0x4cc4)
0x568a  rsp[15] = cksum
0x568e  bl 0x87dc   ; queue Channel-A notify
```

## Internal `mixture_state_t` (16 B @ `0x208c76`) — **high**

| Off | Size | Field | Write (`0x4ae4`) | Read (`0x4b28`) |
|---:|---:|---|---|---|
| 0 | 1 | `state_flag` | set `0xCA` | init checks `== 0xCA` |
| 1..3 | 3 | `start_date_bcd[3]` | `memcpy` from `src[0..2]` | `memcpy` → `rsp[0..2]` (**clobbers opcode**) |
| 4..5 | 2 | `day_anchor` u16 | `today - src[3]` (u8) | `rsp[3] = today - low(day_anchor)` |
| 6..7 | 2 | `month_anchor` u16 | `today - (i8)src[4]` | `rsp[4] = today - month_anchor` |
| **8..12** | **5** | **`period_data`** | **`memcpy` from `src[5..9]`** | **`memcpy` → `rsp[5..9]`** |
| 13..15 | 3 | padding | left 0 | left 0 |

Write source `src` = Channel-A frame bytes `[2..]` (after opcode+sub), so:

```
frame: [0x2B][sub][bcd0][bcd1][bcd2][dayOff][monOff][pd0..pd4]...
         ^0    ^1   ^2    ^3    ^4    ^5      ^6      ^7..^11
```

`period_data` on the wire write is frame `[7..11]` / mixture body
`src[5..9]`. On **internal** record it lives at **`[8..12]`**.

### Wire read frame vs internal offsets

After encode, the 16-byte Channel-A response is:

```
[0..2]  start_date_bcd          (overwrites pre-stamped 0x2B at [0])
[3]     today - day_anchor_lo
[4]     today - month_anchor
[5..9]  period_data[5]
[10..14] zeros
[15]    checksum
```

So on-wire, `period_data` sits at **response bytes 5..9**, not 8..12.
Offsets 8..12 describe the **RAM mixture record** (and the host model that
mirrors that record after re-stamping). Keep both views distinct.

## Every consumer of `period_data` / record `[8..12]`

### 1. Write path — store only

`0x4ae4` (`update_from_frame`):

```text
0x4b16  r0 = record_base
0x4b18  movs r2, 5
0x4b1a  adds r1, r4, 5        ; src+5
0x4b1c  adds r0, 0x22         ; record_base+0x22 = absolute period_data
0x4b1e  bl   memcpy           ; 5 bytes
0x4b22  movs r0, 0xCA
0x4b24  strb r0, [base+0x1a]  ; state_flag
```

No validation, no BCD decode, no range clamp on the 5 bytes.

### 2. Read path — echo only

`0x4b28` (`encode_response`):

```text
0x4b50  r1 = record_base + 0x22
0x4b54  r0 = rsp + 5
0x4b56  movs r2, 5
        bl   memcpy
```

### 3. Lazy init — wipe whole record

`0x4c78`: if `state_flag != 0xCA`, `memset(record, 0, 0x10)` — clears
`period_data` with everything else.

### 4. Phase detector — **does not read period_data**

`0x4b64` loads only:

| Access | Record field |
|---|---|
| `ldrb [base+0x1b]` | `start_date_bcd[0]` (unset if 0) |
| `ldrb [base+0x1d]` | `start_date_bcd[2]` (unset if 0) |
| `ldrb [base+0x1c]` | `start_date_bcd[1]` = cycle length days |
| `ldrh [base+0x1e]` | `day_anchor` |

Day-offset math:

```
t = today + arg + start_date_bcd[2] - day_anchor
; via helper 0x17bd6 (divmod-style)
if cycleLen >= (t_part + 1):  return 2   ; early
elif (start_day - t_part - 9) in [0,9]: return 1  ; mid
else: return 0   ; late
unset: return 3
```

**No load from `base+0x22` (`period_data`).**

### 5. Phase-transition notifier — **does not read period_data**

`0x4c1e` compares RTC date fields against a **different** structure at
`0x208c7c` (`r4` without `-0x20`): bytes at `r4+2..+6` (clock/date snapshot),
then calls phase helper on day args. Fires `0x4c90` on 0→1 or 1→2 transitions.

`0x4c90` motor+UI alert (`bl 0x41b2` pattern 5, `bl 0x354c` with args
`(0x12, 1, 3, 10)`) — **no period_data**.

### 6. Multi-day phase window fillers

`0x4bae` / `0x4bea` loop `bl 0x4b64` only — still no `period_data`.

### 7. Xref surface

Only literal pool hit for `0x208c7c` in body: `0x4cb8` (this module).
No other Thumb site copies length-5 from `base+0x22`.

## Verdict

| Question | Answer | Confidence |
|---|---|---|
| Does firmware **interpret** `periodData[8..12]`? | **No** — store + echo only | **high** |
| Used by phase detector / notifications? | **No** — those use BCD start date + cycle length + day anchor only | **high** |
| Any BCD/day math on those 5 bytes? | **None found** | **high** |
| Why store them? | Host-side blob (app UI / cloud); watch persists and returns | **medium** (intent) |

Firmware **does** interpret **other** mixture fields with day-count math
(`start_date_bcd[1]` as cycle length, anchors as `today − offset`). That math
must not be attributed to `periodData`.

## Host / PROTOCOL notes

- OpenWatch `MenstruationParsed.periodData` @ payload `[8..12]` mirrors the
  **internal record** model. On a raw read frame **without** reassembly,
  the same bytes appear at response `[5..9]` after the encode remapping.
- PROTOCOL already marks `periodData` opaque; static RE strengthens this to
  **“watch does not interpret; host-opaque blob”** rather than “needs more
  firmware RE”. Further decoding is an **app/APK** or live host-capture task,
  not a firmware consumer hunt.

## PROTOCOL.md recommendations

High confidence:

1. State that H59MA v14 **never reads** `period_data` for logic — only
   memcpy on write/read and zero on lazy-init.
2. Optionally note on-wire read placement at response bytes `5..9` vs
   internal `[8..12]`.
3. Phase semantics stay on `start_date_bcd` + anchors; document return codes
   0/1/2/3 as already in GHIDRA.

No new opcodes. No invented field names inside the 5-byte blob.

## Confidence

| Finding | Level |
|---|---|
| Addresses / handler wiring | **high** |
| `period_data` store/echo only | **high** |
| Phase math ignores `period_data` | **high** |
| Host meaning of the 5 bytes | **unknown** (out of firmware scope) |
