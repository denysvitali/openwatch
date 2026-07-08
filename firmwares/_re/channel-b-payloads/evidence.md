# Channel-B Sleep / Activity Payload Layouts

Date: 2026-07-08

Scope: H59MA v14 OTA body `firmwares/_re/v14/body.bin`. Body offsets unless
noted. Flash VA = body + **0x00826400**.

Tooling:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
```

Cross-refs:

- Async dispatcher: `firmwares/_re/channel-b-dispatch/evidence.md`
- Prior decomp notes: `firmwares/GHIDRA_DECOMPILATION.md` §2.1–§2.4, §2.8–§2.10
- History descriptors: GHIDRA § history table (`0x00845a44` cluster)

## Async cascade → handlers (confirmed)

| Cmd | Worker site | Handler body | Flash VA | Role |
|---:|---|---:|---:|---|
| `0x11` | `0x9920` `ldrb r0,[r4]; bl 0x91a2` | `0x91a2` | `0x0082f5a2` | sleep summary |
| `0x12` | `0x992a` `bl 0x910c` | `0x910c` | `0x0082f50c` | sleep detail |
| `0x27` | `0x989e..0x98ac` → `bl 0x96da` | `0x96da` | `0x0082fada` | sleep records |
| `0x2a` | `0x988e` `ldrb r0,[r4]; bl 0xd7bc` | `0xd7bc` | `0x00833bbc` | activity summary |

`0x200e` = day-index helper used as “today” everywhere below.

Frame emitter: `channel_b_queue_notify_frame` @ body `0x88e0`
(`r0`=cmd, `r1`=payload ptr, `r2`=payload length). Builds
`BC | cmd | lenLE | crc16 | payload…`.

---

## `0x11` — sleep summary

### Request

- Payload: `[day_offset]` (1 B). No clamp in handler.
- Effective day = `today - day_offset`.

### Response builder (`0x91a2`)

```text
0x91aa  mov r4, r0                 ; day_offset arg
0x91ac  bl  0x200e                 ; today
0x91b0  subs r0, r0, r4            ; day = today - offset
0x91ba  bl  0xb4c2                 ; sleep_read_summary_record(day, stack_buf)
0x91c6  ldrb r0, [async_payload]   ; echo request day_offset (not recomputed)
0x91c8  strb r0, [rsp]
0x91d0  memcpy(rsp+1, stack_buf, 0x64)
0x91d4  movs r2, 0x65
0x91d8  movs r0, 0x11
0x91da  bl  0x88e0                 ; send 101 B
```

### Wire layout (101 B) — **high confidence**

| Off | Size | Field |
|---:|---:|---|
| 0 | 1 | echoed `day_offset` |
| 1..100 | 100 | summary record (see below) |

Always sends 101 B even when the day is empty (zero-filled body). Matches
GHIDRA §2.1 / §2.9 claim of **101 B**.

### 100-byte summary record — **medium-high** (structure), **medium** (type labels)

Reader `sleep_read_summary_record` @ body `0xb4c2` (`0x008318c2`):

1. If `day == today` and live-ready flag → `FUN` @ `0x1df28` copies live buffer
   `0x20cd48` (100 B).
2. Else ring lookup via `history_desc_sleep_summary_100b` (`0x00845a50` /
   body `0x1f650`), memcpy 100 B or memset 0.

History desc (GHIDRA): flash range `0x00876800..0x00876fff`, stride `0x80`,
16 slots; **copy starts at record offset 0** (includes day key header).

Fields recovered from live-buffer producer (`0x1df28`) + `0x27` packer
(`0x96da`) which reads the **same** 100 B shape:

| Record off | Size | Role | Evidence |
|---:|---:|---|---|
| `+0x00..+0x03` | 4 | day key / header (ring) | history_desc “copy from 0” |
| `+0x04` | 1 | present / session-state flag | `ldrb [buf+4]`; 0 → zero fill |
| `+0x05` | 1 | session sub-state (compared to 1) | live producer gate |
| `+0x06` | 2 | duration-like u16 LE (thresholds 0x3c / 0x5a / 0x78) | live helpers `0x1ab90`, `0x1e680` |
| `+0x08` | 2 | minutes accumulator for **type 3** | producer sums dur into `+8` |
| `+0x0a` | 2 | minutes accumulator for **type 2** | producer sums into `+0xa` |
| `+0x0c` | 2 | minutes accumulator for **type 5** | producer sums into `+0xc` |
| `+0x0e` | 2 | `start_min` u16 LE (minute-of-day) | `0x27` packer `ldrh [rec+0x0e]` |
| `+0x10` | 2 | `end_min` u16 LE (minute-of-day) | `0x27` packer `ldrh [rec+0x10]` |
| `+0x12` | 1 | opaque (not read by `0x11`/`0x27` send path) | — |
| `+0x13` | 1 | pair/segment count `N` | `ldrb [rec+0x13]`; 0 → skip day |
| `+0x14` | `N` | stage **type** bytes | packer: type @ `rec+0x14+i` |
| `+0x3c` | `N` | stage **duration minutes** | packer: dur @ `rec+0x3c+i` |
| mid gap `+0x14+N .. +0x3b` | | unused / reserved for max `N` | max scan uses `0x28` |

Type codes seen in firmware (not full Oudmon 1..4 map):

| Type | Accumulator | Notes |
|---:|---|---|
| 2 | `+0x0a` | summed by live finalizer |
| 3 | `+0x08` | summed by live finalizer |
| 5 | `+0x0c` | **default** new-segment type written at `0x1ea3e` |

Human labels (deep/light/REM) **not** proven from static strings — leave as
type ids. Live capture needed to map 2/3/5 → stages.

### Opaque remainder

- Exact meaning of `+0x00..+0x03` key word packing beyond “day index”.
- `+0x05`, `+0x12`, and any bytes between type/dur arrays when `N` is small.
- Stage-id → sleep-stage mapping.

---

## `0x12` — detailed sleep

### Request

- Payload: `[day_offset]` read from async payload pointer (`state+4`), same as
  other Channel-B commands. Handler does **not** take the offset as a register
  arg (cascade just `bl 0x910c`).

### Response builder (`0x910c`)

```text
0x9114  bl  0x200e
0x911a  day = today - payload[0]
0x9122  bl  0xb4b0                 ; sleep_read_detail_record(day) → ptr or 0
0x9128  r2 = 292 (0x124)           ; pool @ 0x949c
        if ptr: copy/init body
        else:   memset(body, 0, 292)
0x9144  if day_offset == 0:
          hour = minuteOfDay / 60
          bl 0xb1ba                ; sleep_write_live_detail_slot into hour*12+4
0x916a  if guard_day == 0:
          bl 0x8a00 NAK(0x12, day_offset)
        else:
0x9176  r2 = 0x120                 ; 0xff+0x21
          memcpy(rsp+1, body+4, 0x120)
0x9184  r2 = 0x121                 ; 0xff+0x22
0x918a  movs r0, 0x12
          bl 0x88e0
```

### Wire layout (289 B) — **high confidence**

| Off | Size | Field |
|---:|---:|---|
| 0 | 1 | echoed `day_offset` |
| 1..288 | 288 (`0x120`) | 24 × 12 B hourly slots (body without 4 B day key) |

Matches GHIDRA §2.2 / §2.10 (**289 B**). NAK path uses compact
`channel_b_send_nak(0x12, day_offset)` when RTC day guard is 0.

History desc `history_desc_hourly_detail_24x12` (`0x00845a44`): key @ `+0`,
24 × 12 B slots @ `+4`. Response strips the key (memcpy from `body+4`).

### 12-byte hourly slot (live overlay writer `0xb1ba`) — **medium**

`sleep_write_live_detail_slot` writes into the current hour’s slot:

| Slot off | Size | Compute |
|---:|---:|---|
| 0..1 | u16 LE | `state+4 − state+8` |
| 2..3 | u16 LE | `state+0x38 − state+0x3c` |
| 4..5 | u16 LE | `(state+0x1c − state+0x20) / 100` |
| 6..7 | u16 LE | `(state+0x14 − state+0x18) / 10` |
| 8 | u8 | `state+0x30 − state+0x34` |
| 9..11 | 3 | **not written** by this helper (left from flash copy / zero) |

Semantic names (steps/cal/HR/…) **not** recovered — only delta math against
the live sleep-detail state block at `0x20c02c − 0x40`.

### Opaque remainder

- Full meaning of each u16 in the 12 B slot.
- Bytes 9..11 of each slot.
- Whether empty days always NAK vs zero-fill (code zero-fills then still
  requires non-zero day guard to send data).

---

## `0x27` / `0x3e` — sleep records

### Request

| Byte | Field |
|---:|---|
| 0 | `maxDayOffset` — clamped to **6** |
| 1 | `recordType` — if length &lt; 2 treated as **0**; **1** enables nap pass |

Worker:

```text
0x989e  cmp r1, 1          ; length
        bls → recordType = 0
        else recordType = payload[1]
0x98ac  bl 0x96da
```

### Response builder (`0x96da`)

1. `baseDay = today - maxOffset`.
2. **If `recordType == 1`:** loop `i = 0..maxOffset`,
   `sleep_read_nap_record(baseDay+i)` (`0xb508`), pack records, emit **one**
   frame cmd **`0x3e`**.
3. **Always:** same loop with `sleep_read_summary_record` (`0xb4c2`), emit
   **one** frame cmd **`0x27`**.

Nap reader uses history_desc `history_desc_sleep_nap_100b` (`0x00845a5c`) with
key tag `day | 0x00bb0000`; same 100 B body layout as night summary.

### Wire layout — **high confidence**

```
payload[0]     = recordCount   (number of day-records emitted)
payload[1..]   = record*
```

Each record:

| Off | Size | Field | How written |
|---:|---:|---|---|
| 0 | 1 | `dayDelta` = `maxOffset - loopIndex` | `subs r0,r6,r7` |
| 1 | 1 | `blockLen` = `2*N + 4` | `N` from summary `+0x13` |
| 2..3 | 2 | `startMin` u16 **LE** | from summary `+0x0e` |
| 4..5 | 2 | `endMin` u16 **LE** | from summary `+0x10` |
| 6.. | `2*N` | pairs `(type, durMin)` | type `+0x14+i`, dur `+0x3c+i` |

`blockLen` covers start/end (4 B) + pair bytes only (not dayDelta/blockLen).
Days with `N==0` are skipped (no record entry). Empty night still emits
`0x27` with `recordCount=0` and length 1.

Cross-check: matches host `SleepParser.isH59maNightRecordPayload` and
PROTOCOL §4.4 count-prefixed shape. GHIDRA §2.3 header description is
slightly imprecise (“score bytes”) — wire is **(type, durMin) pairs**.

### Opaque remainder

- Stage type byte values beyond {2,3,5} used in live path.
- Whether older BE single-block captures can still appear on v14 (handler
  only emits the count-prefixed shape).

---

## `0x2a` — activity / sport summary

### Request

- Payload: `[maxDayOffset]`, **clamped to 2** (so offsets `2,1,0`).
- Negative after clamp → empty send path (`length=0` still calls emitter).

### Response builder (`0xd7bc`)

```text
0xd7ca  if n >= 3: n = 2
0xd7d0  if n < 0:  goto empty
loop d = n .. 0:
0xd7da  bl 0xd742  activity_read_day_summary_record(today-d, buf52)
        if ok:
          rsp[out] = d
          memcpy(rsp+out+1, buf52+4, 0x30)   ; skip 4 B key
          out += 0x31
0xd7fe  movs r0, 0x2a
        bl 0x88e0(out)   ; out may be 0
```

### Wire layout — **high confidence**

Repeated entries, total length `0x31 * k` for `k ∈ 0..3`:

| Off | Size | Field |
|---:|---:|---|
| 0 | 1 | `day_offset` (`d` in the loop) |
| 1..48 | 48 | activity body |

`day_offset == 0` is valid (today). Parse by **payload length**, not zero
terminator. Max payload **0x93** (147 B). Matches GHIDRA §2.4 / §2.8.

### 48-byte body — **high confidence structure**, **low confidence sample units**

Reader `activity_read_day_summary_record` @ `0xd742` (`0x00833b42`):

1. `memset(out, 0, 0x34)` — internal 52 B record.
2. Ring lookup `history_desc_activity_daily_24x2` (`0x00845a98`).
3. If found: copy 52 B, then for `i in 0..23`: if body byte `out[4+2*i] == 0xFF`
   or `out[5+2*i] == 0xFF`, replace with `0` (FF→0 hole fill).
4. Live overlay from `activity_state+0xc` when day matches: writes 2 sample
   bytes into slot `slotIndex`.
5. Returns 1 on success / cache hit; 0 → day omitted from response.

History desc body: **key @ +0**, **24 samples × 2 B @ +4**. Channel-B sends
only the 48 B sample array.

| Body off | Size | Field |
|---:|---:|---|
| `0 + 2*h` | 2 | hour `h` sample pair (raw); `0xFF` means empty → host should treat as 0 |

**Not** a u24 steps/kcal/distance header. Host-side
`_activityTotalsFromBody` u24-BE guess is **not** supported by static RE;
needs live correlation against Channel-A `0x48` / `0x43` or pedometer state.

### Opaque remainder

- Meaning of each sample’s 2 bytes (steps low/high? intensity? flags?).
- Endianness if interpreted as u16.
- How samples relate to Channel-A `0x43` 12 B hourly sport slots.

---

## GHIDRA cross-check summary

| Claim | Status |
|---|---|
| `0x11` = 101 B (`1+100`) | ✅ confirmed |
| `0x12` = 289 B (`1+288`), 24×12 | ✅ confirmed |
| `0x27` count-prefixed records, nap→`0x3e` | ✅ confirmed |
| `0x2a` ≤3 × 49 B, clamp max offset 2 | ✅ confirmed |
| Activity 48 B = 24×2 after key | ✅ confirmed via history_desc + reader |
| Sleep summary “deep/light/REM/HR” names | ❌ not static-proven; only type 2/3/5 buckets |
| Detailed sleep slot field names | ❌ only live delta math recovered |
| Activity body as totals | ❌ contradicted; samples not totals |

---

## PROTOCOL.md recommendations

High confidence (safe to document):

1. **`0x2a` body** = 24 × 2-byte hourly samples; `0xFF` → 0; not u24 totals.
2. **`0x11` / `0x27` shared summary**: `startMin`/`endMin` @ `+0x0e`/`+0x10`,
   count @ `+0x13`, pairs at `+0x14` / `+0x3c` (document as summary-record
   layout used to build `0x27` records).
3. Keep **`0x12`** as 24 × 12 B; note live overlay fills first 9 B of current
   hour only.

Live-capture needs:

- Map sleep type bytes {2,3,5,…} → stages.
- Map activity 2-byte samples → steps/intensity.
- Name the 12 B sleep-detail slot fields.
- Confirm `+0x08/+0x0a/+0x0c` minute totals vs UI sleep score card.

## Confidence

| Area | Level |
|---|---|
| Handler addresses / lengths / clamps | **high** |
| `0x27` record packing | **high** |
| Activity 24×2 structure | **high** |
| Summary record field offsets | **medium-high** |
| Type/stage and sample semantics | **low** (needs live capture) |
