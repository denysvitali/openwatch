# Persistent History Record Field Layouts (Producer-Side)

Date: 2026-07-08

Firmware: H59MA v14 OTA body `firmwares/_re/v14/body.bin`  
Base: flash `0x00826400` (body_off = flash − base)

Tooling:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
# Ghidra: decompile + xrefs on labeled ring helpers / Channel-A handlers
```

Cross-refs:

- Wire projection: `firmwares/_re/channel-b-payloads/evidence.md`
- BP compact slots: `firmwares/_re/bp-slot-encoding/evidence.md`
- Descriptor table: GHIDRA § history descriptors (`0x00845a44` cluster)
- Prior decomp: `firmwares/GHIDRA_DECOMPILATION.md` §2.x / §3.6 / §3.12 / §3.20–§3.21 / §8.13

Scope: decode **persistent record bodies from producers** (writers + live
overlays), not just Channel-A/B response packing.

---

## Descriptor recap (confirmed)

| Desc | Flash | Range | Stride | Body (after key) | Consumers |
|---|---:|---|---:|---|---|
| hourly detail 24×12 | `0x00845a44` | `0x00874000..0x00875fff` | `0x200` | 24 × 12 B | Ch-A `0x43`, Ch-B `0x12` |
| sleep summary 100 B | `0x00845a50` | `0x00876800..0x00876fff` | `0x80` | full 100 B incl. key | Ch-B `0x11`/`0x27` |
| sleep nap 100 B | `0x00845a5c` | `0x00876000..0x008767ff` | `0x80` | same shape; key `day\|0x00bb0000` | Ch-B `0x3e` |
| “activity” daily 24×2 | `0x00845a98` | `0x00877000..0x00877fff` | `0x80` | 24 × 2 B | Ch-B `0x2a` |
| HR 5-min | `0x00845aac` | `0x00878000..0x00879fff` | `0x200` | 288 × 1 B | Ch-A `0x15` |
| BP hourly | `0x00845ae4` | `0x0087a000..0x0087afff` | `0x80` | 24 × 4 B | Ch-A `0x0e`/`0x0d` |
| pressure 30-min | `0x00845af0` | `0x0087b000..0x0087bfff` | `0x100` | 48 × 1 B | Ch-A `0x37` |
| HRV 30-min | `0x00845afc` | `0x0087c000..0x0087cfff` | `0x100` | 48 × 1 B | Ch-A `0x39` |

Shared writer: `history_ring_upsert_record_body` @ `0x008295c6`
(`desc, cursor, key, body_offset, src, len`).

---

## 1. Sleep summary types / durations

### 1.1 100-byte record layout — **high** (structure)

Live buffer / persisted summary @ SRAM `0x0020cd48` (`DAT_008443b4`):

| Off | Size | Field | Producer notes | Conf |
|---:|---:|---|---|---|
| `+0x00` | 4 | day key (u32) | set from `FUN_00840f30` day helper | high |
| `+0x04` | 1 | session present / quality flag | live finalizer writes `1` or `3`; synthetic sets `2` | med-high |
| `+0x05` | 1 | sub-state / cycle counter | incremented on long gap fill; synthetic bumps on type-0 | med |
| `+0x06` | 2 | total duration minutes (u16 LE) | summed segment durs | high |
| `+0x08` | 2 | minutes sum for **type 3** | only type `3` | high |
| `+0x0a` | 2 | minutes sum for **type 2** | only type `2` | high |
| `+0x0c` | 2 | minutes sum for **type 5** | only type `5` | high |
| `+0x0e` | 2 | `start_min` u16 LE | minute-of-day | high |
| `+0x10` | 2 | `end_min` u16 LE | minute-of-day; wraps mod `0x5a0` (1440) | high |
| `+0x12` | 1 | opaque score-ish | passed to `FUN_00844428` if `0x29..0x51` | low |
| `+0x13` | 1 | segment count `N` (max scan 0x28=40) | | high |
| `+0x14` | ≤40 | type bytes | parallel array | high |
| `+0x3c` | ≤40 | duration minutes (u8 each) | parallel array; values can be `0xFF` chunks | high |

Re-sum path: `FUN_00844328` (`0x00844328`) zeroes `+8/+a/+c` then walks
`i < N` and adds `dur[i]` into the matching type bucket (**only 2, 3, 5**).

Commit: `FUN_008316fe` → upsert 100 B into `history_desc_sleep_summary_100b`.
Nap twin: `FUN_008316be` ORs key with `0x00bb0000` into nap desc.

### 1.2 Type constants written by producers — **high** (constants), **low** (clinical labels)

| Type | Written by | Role in firmware | Accumulator |
|---:|---|---|---|
| `0` | live gap filler when gap ≥ 120 min; synthetic (prng tail / forced) | long inter-segment gap / “off” | **none** |
| `2` | synthetic only (dominant ~60% of synthetic draws) | segment class | `+0x0a` |
| `3` | synthetic; live session-quality path can set flag byte to 3 | segment class | `+0x08` |
| `4` | synthetic only (~12% band) | segment class | **none** |
| `5` | live default for continuing/new short segments; synthetic | default live stage | `+0x0c` |

**No type `1` as a stage id** in either live or synthetic writers. Value `1`
appears as session **flag** at `+0x04` / `+0x05`, not as `types[i]`.

#### Live writer — `sleep_append_live_summary_segment` @ flash `0x00844cf0` (body `0x1e8f0`)

Args: `(start_or_anchor_min, duration_min, type_hint)`.

Behaviour (abridged):

1. If summary empty (`+0x06 == 0`): zero buffer, set day key, `start_min`,
   `N=0`, session flag `+0x05=1`, seed duration.
2. If `end_min == param_1` and `type_hint == 5`: append pair `(5, duration)`.
3. Else compute gap = `param_1 − previous_end` (mod 1440):
   - gap `< 0x78` (120): **no** type/dur pair for the gap.
   - gap `≥ 0x78`: fill with type **`0`**, duration chunks of at most `0xFF`
     (loop: if gap > 255 write `(0, 0xFF)` and subtract 255).
4. Always update `end_min`, add duration into `+0x06`.

Default type constant materialised at body `0x1e94a` / `0x1ea3e`:
`movs r0/r2, #5` then `strb` into `types[N]`.

#### Synthetic writer — `fee7_generate_synthetic_sleep_record` @ `0x00844214`

FEE7 `0xfe` path. Clamps duration to 900 min. While remaining minutes > 0 and
`N < 40`, draws `prng % 100`:

| `prng%100` | Type | Duration formula |
|---:|---:|---|
| `< 0x3c` (60) | **2** | `(prng % 0x5a) + 0x1e` → 30..119 |
| `< 0x50` (80) | **3** | `(prng % 0x1e) + 0xf` → 15..44 |
| `< 0x5c` (92) | **4** | `(prng % 0x14) + 10` → 10..29 |
| `< 0x62` (98) | **5** | `(prng % 0x14) + 5` → 5..24 |
| else / forced | **0** | `(prng % 0x1e) + 0x1e` or `+0x46`; bumps `+0x05` |

Also sets `+0x04 = 2` (session present code distinct from live `1`/`3`).

#### Comparison / gate sites (not stage renames)

| Site | Check | Effect |
|---|---|---|
| `FUN_00844328` | `type == 2/3/5` | minute buckets only |
| `sleep_append…` | `type_hint == 5` | continue segment |
| `sleep_append…` | gap `≥ 0x78` | emit type `0` |
| `FUN_00844a80` | session flags / total ≥ 0x59 | “session valid” gate |
| `FUN_00844428` | `+0x12` in `0x29..0x51` | copies into side state (+10) |

### 1.3 Stage semantics — **not static-proven**

Firmware has **no** string table or enum naming deep/light/REM/awake.
Safe publication:

- Treat types as opaque stage ids `{0,2,3,4,5}`.
- Type `0` = long gap filler (live) / synthetic off-segment.
- Types `2/3/5` = only ones that contribute to summary minute totals.
- Type `4` only appears on synthetic path (and would survive round-trip if
  present on disk).
- Mapping to clinical sleep stages **requires live capture** against a host
  that already labels graphs.

---

## 2. 12-byte hourly detail slot (sport counters)

### 2.1 Shared table identity — **high**

`history_desc_hourly_detail_24x12` is the **same** body for:

- Channel-B `0x12` “detailed sleep” (288 B = 24×12 after stripping key)
- Channel-A `0x43` “readDetailSport”

There is **no** separate sleep-stage curve table. Sleep stages live only in
the 100 B summary. Hourly detail is pedometer/sport deltas.

Record: `key u32 @ +0` + `24 × 12 B @ +4` = 292 B (`0x124`).

### 2.2 Slot field layout from producer — **high**

Live state block base `0x0020bfec` (`DAT_00831d94` / sport_state).
Hour baseline snapshots at paired “previous” offsets.

Writer `sleep_write_live_detail_slot` @ `0x008315ba` (body `0xb1ba`):

| Slot off | Size | Formula (current − baseline) | Sport-state source | Conf |
|---:|---:|---|---|---|
| `+0` | u16 LE | `steps_cur − steps_base` | `+0x04` / `+0x08` | **high** — `sport_state_get_steps` reads `+0x04`; add capped at 99999 (`0x1869F`) |
| `+2` | u16 LE | `metric38_cur − metric38_base` | `+0x38` / `+0x3c` | **med** — getter exists; not in `0x48` today-sport frame |
| `+4` | u16 LE | `(cal_raw_cur − cal_raw_base) / 100` | `+0x1c` / `+0x20` | **high** — `sport_state_get_calories_div100` = `(+0x1c)/100` |
| `+6` | u16 LE | `(dist_cur − dist_base) / 10` | `+0x14` / `+0x18` | **high** — `sport_state_get_distance` reads `+0x14` |
| `+8` | u8 | low-byte delta of `+0x30` pair | `+0x30` / `+0x34` | **med** — `sport_state_get_elapsed_seconds` is u16 @ `+0x30` |
| `+9..+11` | 3 | **not written** by live slot writer | left 0 / prior flash | high |

Accumulator inverse: `sleep_accumulate_live_detail_slot` @ `0x008315f8`
adds slot fields back into the live totals (×100 / ×10 where divided).

Hour baseline reset: `FUN_00831630` copies current→baseline for all five pairs.

### 2.3 Readers / aggregators — **high**

`FUN_00831bb4` sums hourly slots by metric selector:

| `param_1` | Slot field used | Live remainder |
|---:|---|---|
| 0 | u16 @ slot+0 (steps) | `+4 − +8` |
| 1 | u8 @ slot+8 | `+0x30 − +0x34` |
| 2 | u16 @ slot+4 (cal/100 units) | `+0x1c − +0x20` |
| 3 | u16 @ slot+6 (dist/10 units) | `+0x14 − +0x18` |

Empty-slot sentinel: `DAT_00831da4` / `DAT_0082d438` treated as skip
(historically `0xFFFF` on steps field).

### 2.4 Persistence path — **high**

- `FUN_00831662` / `FUN_00831722`: compute current hour slot →
  `history_ring_upsert_record_body(desc_hourly, day, hour*12+4, slot, 12)`.
- `channel_a_send_device_notify(4)` after some writes.

---

## 3. Activity daily 24×2 (`0x2a` body) — SpO2 max/min hours

### 3.1 Record layout — **high**

| Off | Size | Field |
|---:|---:|---|
| `+0` | 4 | day key |
| `+4 + 2*h` | 2 | hour `h` sample pair |

Reader `activity_read_day_summary_record` @ `0x00833b42`:

1. `memset(out, 0, 0x34)`.
2. Ring lookup; copy 52 B.
3. For each of 24 pairs: if either byte is `0xFF`, replace that byte with `0`.
4. If live day matches: overlay `state+0x10` / `state+0x11` at hour
   `state+0xe`.

Channel-B `0x2a` sends `day_offset ‖ body[4..51]` (49 B per day).

### 3.2 Sample producer — **high** (structure), **med-high** (SpO2 domain)

Live state @ `0x0020c2f4` (`activity_state_ptr`):

| Off | Field |
|---:|---|
| `+0` | last accepted measurement (`spo2_current_value`) |
| `+1` | auto-measure tick |
| `+0xc` | live day index |
| `+0xe` | live hour index |
| `+0x10` | running **max** for current hour |
| `+0x11` | running **min** for current hour |

`FUN_00833a56` (body `0xd656`) on each sample `v ≠ 0`:

```text
day/hour = now
if max == 0: max = min = v
else:
  if v > max: max = v
  if v < min: min = v
notify(3)
```

So each 2-byte sample is **`(max_u8, min_u8)`**, not a u16 LE step count.

Value shaping `FUN_00833a24`:

- if `v < 0x5b` (91): replace with `(prng % 4) + 0x5d` → **93..96**
- if `v > 100`: clamp to **100**
- else store `v`

Timeout synthetic `FUN_00833a94`: `(prng % 7) + 0x5d` → **93..99**.

Measure mask `0x80`. Ghidra already names `*activity_state_ptr` reader
`spo2_current_value`. Value domain is percent-like 0..100, **not** step
counts.

Flash upsert `FUN_00833c0c`: writes the 2 live bytes at
`offset = hour*2 + 4`, then clears the 6-byte live day/hour/sample header.

### 3.3 Endian / `0xFF` — **high**

- Not a single u16; two independent u8s.
- `0xFF` = uninitialised hole → reader forces `0` (host should treat same).

---

## 4. Heart-rate 5-minute table + Channel-A `0x15`

### 4.1 Persistent record — **high**

| Off | Size | Field |
|---:|---:|---|
| `+0` | 4 | day key = `epoch_seconds / 86400` (`0x15180`) |
| `+4` | 288 | one BPM byte per 5-minute slot (`24*60/5`) |

Writer `FUN_00833c54` @ `0x00833c54` (body `0xd854`):

```text
if bpm-0x28 > 0xb4: return          ; accept only roughly 40..220 before store
day  = seconds / 86400
slot = (seconds % 86400) / 300      ; 5 minutes
upsert(desc_hr, day, slot+4, &bpm, 1)
notify(1)
```

Reader `FUN_00833c92` @ `0x00833c92`:

- copies 288 sample bytes
- zeroes any sample where `(bpm - 0x28) > 0xb4` i.e. outside **40..220**

### 4.2 Auto-measure → sample — **med-high**

Timer path around body `0xd8f6..0xd9aa` (flash ~`0x00833cf6`):

- Reads sensor BPM; sanitises with PRNG fallbacks into 40–220-ish band
  (paths adding `0x32` / `0x5a` / `0x5f` after `prng % 10`).
- Calls writer with accepted BPM.

### 4.3 Wire projection `0x15` — **high** (reconfirmed)

Handler `channel_a_handle_read_heart_rate` @ `0x0082cf48`:

1. Request index u32 LE @ `req[1..4]`; `0` → timestamp 0 (latest path via
   converter), else `FUN_008279c4(index, &ts)`.
2. `FUN_00833c92(ts, buf292)`; on miss: error frame `0x15 0xFF …` with
   status dword `0x140000FF15`.
3. On hit: **overwrite `buf[0..3]` with request index**, header
   `0x05180015` shape (`0x5180015`), then 23 × 13 B chunks (`0x124` bytes).

Reassembled host buffer:

| Off | Size | Field |
|---:|---:|---|
| 0 | 4 | echoed request index (not day key) |
| 4 | 288 | BPM samples (slot 0 = 00:00–00:05 local day) |

Note: GHIDRA §3.12 older text claiming “72 × u32 fields” is **wrong** —
producer is 288×u8 BPM. Corrected here / in PROTOCOL.

---

## 5. Pressure (stress) + HRV 30-minute histories

### 5.1 Shared record body — **high**

Both descriptors: `key u32 + 48 × u8 samples`.

| Metric | Desc | Writer | Reader | Current-value |
|---|---|---|---|---|
| pressure/stress | `0x00845af0` | `FUN_008344c8` | `pressure_history_read_day` `0x008344fe` | `pressure_current_value` @ state−8 |
| HRV | `0x00845afc` | `FUN_00834654` | `hrv_history_read_day` `0x0083468e` | `hrv_current_value` @ state+7 |

Writer common pattern (asm-confirmed):

```text
sample_byte = r0
if sample_byte == 0: return
day = rtc_day_index()
slot = minute_of_day / 0x1e          ; 30 minutes → 0..47
upsert(desc, day, slot+4, &sample_byte, 1)
notify(pressure=0x2c / hrv=0x2b)
```

Reader:

```text
copy key
for i in 0..47:
  out[i] = 0 if src[i] in {0x00, 0xFF} else src[i]
return 0x30  ; or 0 if missing
```

### 5.2 Sample value domains from auto-measure timers — **high** (ranges), **low** (clinical)

**Pressure timer** `FUN_0083455e`:

- After warm-up ticks, if live value `0` until tick ≥ `0x32`:
  store `(prng % 0x14) + 0x1e` → **30..49**.
- If live value outside **`[0x14, 0x41]` (20..65)**: replace with same PRNG band.
- Else store live byte; then `FUN_008344c8(v)`.

**HRV timer** `FUN_008346ec`:

- Timeout tick ≥ `0x3c` with zero: PRNG **30..49**.
- Valid band **`[0x1e, 0x32]` (30..50)**; outside → PRNG replace.
- Then `FUN_00834654(v)`.

These are **single opaque score bytes**, not multi-field HRV statistics
(no RMSSD/SDNN packing in the store path). Same synthetic style as BP
compact (see `bp-slot-encoding/evidence.md`).

### 5.3 Wire fragmenter — **high**

Handlers `0x0082caa6` (`0x37`) / `0x0082c9da` (`0x39`):

1. `read_day(day_offset, buf52)` → 0 ⇒ `0xFFxx` error frame.
2. Header dword `0x1E050037` / `0x1E050039`.
3. `buf[0] = day_offset` (echo), stream **49 B** via
   `channel_a_send_sequenced_13byte_chunks` (4 frames × 13 B).

Payload after reassembly:

| Off | Size | Field |
|---:|---:|---|
| 0 | 1 | day_offset echo |
| 1..48 | 48 | half-hour samples, chronological from 00:00 |

---

## 6. Channel-A `0x43` detail sport frames (from same 12 B slots)

### 6.1 Day buffer — **high**

Handler `channel_a_handle_detail_sport_read` @ `0x0082d034`:

1. `sleep_read_detail_record(today − day_offset)` → 292 B or zero-fill.
2. If `day_offset == 0`: overlay current hour via
   `sleep_write_live_detail_slot`.
3. Scan hours `[start_hour, end_hour]` (today clamps end to current hour).

Skip rules per slot (field names = slot layout §2):

| Condition | Action |
|---|---|
| `steps==0` and `dist_div10==0` | skip empty |
| `steps == 0xFFFF` sentinel | skip |
| else | include |

### 6.2 Header frame — **high**

| Byte | Value |
|---:|---|
| 0 | `0x43` |
| 1 | `0xF0` if any slots, else `0xFF` |
| 2 | record count |
| 3 | unit_flag echo (`1` if `req[5]==1`) |
| 15 | checksum |

### 6.3 Per-slot data frame packing — **high** (bytes), **high** (field sources)

From decompiled stores into the 16-byte notify buffer:

| Byte | Field | Source |
|---:|---|---|
| 0 | `0x43` | const |
| 1 | year BCD | `u8_to_bcd(year_off)` |
| 2 | month BCD | |
| 3 | day BCD | |
| 4 | `hour_index << 2` | slot index |
| 5 | record ordinal | 0..count-1 |
| 6 | 0 | |
| 7 | `dist_scaled` lo | slot`+6` × (10 if `unit_flag==0` else 1) |
| 8 | `dist_scaled` hi | |
| 9 | steps lo | slot`+0` |
| 10 | steps hi | |
| 11 | cal_div100 lo | slot`+4` |
| 12 | cal_div100 hi | |
| 13–14 | 0 | |
| 15 | checksum | |

So host reconstruction per non-empty hour:

- **steps** = u16 from bytes 9..10 (LE as packed)
- **calories units** = u16 from bytes 11..12 (= slot field already `/100`)
- **distance units** = u16 from bytes 7..8; if `unit_flag==0` firmware already
  ×10’d the slot’s `/10` value back toward raw distance

Slot fields `+2` (metric38) and `+8` (elapsed low) are **not** projected on
`0x43` wire (only on raw Ch-B `0x12` / flash image).

### 6.4 Relation to Ch-B `0x12` — **high**

| Path | Payload |
|---|---|
| Ch-B `0x12` | full 24×12 raw bytes (incl. unused `+2/+8/+9..11`) |
| Ch-A `0x43` | sparse non-empty hours, 3 metrics only, BCD date, unit_flag |

---

## 7. BP hourly (already decoded — pointer)

See `firmwares/_re/bp-slot-encoding/evidence.md`:

- slot = `[compact, 0, 0, 0]`
- compact = HR bpm or timeout PRNG 70..74
- **not** cuff sys/dia in v14 store path

---

## Confidence matrix

| Area | Level | Notes |
|---|---|---|
| Descriptor geometry / keys | **high** | table + readers |
| Sleep summary offsets + type constants | **high** | live + synthetic writers |
| Sleep type → clinical stage names | **low** | no strings; live capture needed |
| 12 B slot = steps/cal/dist deltas | **high** | getters + writer math |
| Slot `+2` / `+8` clinical names | **medium** | counters known, labels weak |
| `0x2a` = max/min SpO2-like % | **med-high** | clamp 100 + spo2 label + measure path |
| HR 288×u8 BPM | **high** | writer/reader |
| Pressure/HRV 48×u8 score | **high** layout; **low** clinical |
| `0x43` packing | **high** | decompile stores |
| BP compact | **high** | prior evidence |

---

## PROTOCOL.md / GHIDRA update checklist

Safe to promote:

1. Sleep types `{0,2,3,4,5}` with accumulator rules; forbid invented stage names.
2. Hourly 12 B slot field table (steps / cal÷100 / dist÷10 / …).
3. `0x2a` body = 24×`(max,min)` SpO2-like samples; `0xFF→0`.
4. `0x15` body = 4 B index echo + 288 BPM bytes (not u32 triples).
5. `0x37`/`0x39` = 48 half-hour score bytes; producer ranges.
6. `0x43` per-frame metric mapping from the same 12 B slots.

---

## Open (still need live capture)

- Map sleep types 2/3/4/5 → deep/light/REM/awake on a real night graph.
- Confirm SpO2 clinical identity of `0x2a` against finger/watch SpO2 UI.
- Name sport_state `+0x38` and exact unit of distance raw (`+0x14`).
- Pressure/HRV score ↔ UI “stress” / “HRV” numeric scales.
