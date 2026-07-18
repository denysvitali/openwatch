# H59MA v14 persistent settings / config field maps

Date: 2026-07-08

Firmware: `firmwares/_re/v14/body.bin`  
Flash VA base: **body + `0x00826400`**  
Tooling: radare2 (`-a arm -b 16 -e asm.cpu=cortex`), Ghidra decompile, Capstone for base+offset recovery.

Cross-refs: GHIDRA §5.3, `firmwares/_re/config-blob/evidence.md`, `firmwares/_re/period-data/evidence.md`, PROTOCOL Channel-B `0x2c` / `0x5a`.

## Storage model (three parallel stores)

| Store | Flash slot | RAM base | Length | Magic | Commit |
|---|---:|---:|---:|---|---|
| **settings blob0** | `0x0000` | `0x200088fc` | `0xe0` (224) | byte `0x04` at `+0` | `settings_blob0_commit` `0x008294cc` |
| **user_config** | `0x0200` | `0x20008c8c` | `0xa4` (164) | u32 LE `0xa1b2c3e5` at `+0` | `user_config_block_commit` `0x0082954a` |
| **settings blob1** | `0x0400` | `0x200089dc` | `0x2b0` (688) | byte `0x07` at `+0` | `settings_blob1_commit` `0x00829456` |
| **cfg item blob** | flash `0x00801400` | same | variable | u32 LE `0x8721bee2` | `cfg_upsert_items_and_rewrite_blob` `0x008409f8` |

RAM packing (contiguous, not flash-slot order):

```
0x200088fc  blob0   0xe0 B
0x200089dc  blob1   0x2b0 B
0x20008c8c  user_config 0xa4 B
```

Offset-store load helpers: `func_0x00007b1e(dst, flash_off, len)`; commit: `func_0x00007b32(src, flash_off, len)`.

Boot order (`app_init` cluster): `settings_blob0_load_or_init` → `user_config_load_or_init` → feature modules (alarms live inside blob1).

---

## 1. Settings blob0 — `0xe0`, magic `0x04`

**Load/init:** `settings_blob0_load_or_init` `0x008294e0`  
Loads slot `0`; if `*base != 0x04` zero-fills RAM `0xe0` and returns 0.  
**Commit:** forces `*base = 0x04`, writes flash slot `0`.

### Field map (offsets from `0x200088fc`)

| Off | Size | Field | Evidence / writers | Conf |
|---:|---:|---|---|:---:|
| `+0x00` | 1 | **magic** `0x04` | load/commit | high |
| `+0x01..+0x03` | 3 | pad / unused in scanned paths | — | low |
| `+0x04` | 4 | **session_mode** (u32: `0/1/2`) | FEE7 `0x98`/`0x9a` → `fee7_set_session_mode_and_commit`; commits blob0 | high |
| `+0x06..+0x09` | — | BLE name-build scratch reads | `ble_build_device_name_and_adv_data` | med |
| `+0x15` | 1 | status nibble cluster (read in FEE7/model paths) | `fee7_send_fw_version_build_info_93` | med |
| `+0x18..+0x1f` | 8 | name-template / prefix words | copied into adv name build | med |
| `+0x20..+0x25` | 6 | **fallback MAC** (when no TLV-2 override) | `ble_gap_profile_register` if `+0x60==1` | med |
| `+0x26` | 1 | **watchface label slot_id** (`0xa0..0xa5` style) | `watchface_label_commit_ble_name_refresh` | high |
| `+0x27..+0x3a` | ≤20 | **watchface label text** | same; cleared/`memcpy` on `0x18` label styles | high |
| `+0x3e` | 2 | live counter / factory-test related u16 | factory-test poll | med |
| `+0x40..+0x42` | 2+2 | step-ish live u16 pair | factory-test / status frames | med |
| `+0x48..+0x50` | 4×3 | factory-test live state words | `factory_test_poll_timer_cb` | med |
| `+0x60` | 1 | **use_blob_mac** flag (`==1` → take MAC from `+0x20`) | `ble_gap_profile_register` | high |
| `+0x7a` | `0x14` | **TLV id 3** device-info string | Ch-B `0x5a` store; enable `+0xd5[1:0]==1` | high |
| `+0x8e` | `0x10` | **TLV id 4** device-info string | enable `+0xd5[3:2]==1` | high |
| `+0x9e` | `0x10` | **TLV id 5** / custom FW version string | enable `+0xd5[5:4]==1`; FEE7 `0x93` | high |
| `+0xae` | `0x08` | **TLV id 6** / custom build-date string | enable `+0xd5[7:6]==1`; FEE7 `0x93` | high |
| `+0xb6` | `0x18` | **TLV id 1** custom advertised name/prefix | enable `+0xd6[1:0]==1` | high |
| `+0xce` | `0x06` | **TLV id 2** BLE address override | enable `+0xd6[3:2]==1`; also `cfg_update_mac_item` | high |
| `+0xd4` | 1 | **TLV id 7** name-format control (not returned by query) | Ch-B `0x5a` write | high |
| `+0xd5` | 1 | **string-slot enable pairs** (2 bits × 4 slots ids 3–6) | value `==1` means enabled for that pair | high |
| `+0xd6` | 1 | **name/MAC enable pairs** (bits `1:0` name, `3:2` MAC) | | high |
| `+0xd7` | 1 | alarm-module side flag (`FUN_00827a00`) | set on alarm init path | med |
| `+0xd8..+0xdf` | — | end of blob0 / unused in high-confidence paths | — | low |

### Channel-B `0x5a` TLV ↔ blob0 (confirmed)

| TLV id | Dest | Max clear | Enable |
|---:|---|---:|---|
| 1 | `+0xb6` | `0x18` | `+0xd6` bits 1:0 = 1 |
| 2 | `+0xce` | 6 | `+0xd6` bits 3:2 = 1 (+ `cfg_update_mac_item`) |
| 3 | `+0x7a` | `0x14` | `+0xd5` bits 1:0 = 1 |
| 4 | `+0x8e` | `0x10` | `+0xd5` bits 3:2 = 1 |
| 5 | `+0x9e` | `0x10` | `+0xd5` bits 5:4 = 1 |
| 6 | `+0xae` | `0x08` | `+0xd5` bits 7:6 = 1 |
| 7 | `+0xd4` | 1 | none |

Subcmd `4`: `memset(+0x7a, 0, 100)` + commit blob0 (clears string slots + flags through `+0xdd`, does **not** refresh cfg item `0x33`).

Channel-A `0x81`: writes 6 B to `blob0+0xce` (same MAC slot), dirty flag, `settings_blob0_commit`, `cfg_update_mac_item`.

---

## 2. Settings blob1 — `0x2b0`, magic `0x07`

**Load:** `FUN_00829424` / load-or-init cluster at body `0x3024`  
**Commit:** `settings_blob1_commit` / `settings_blob1_commit_if_changed`  
**Factory defaults:** `FUN_00827446` (`0x00827446`) — fill `0xff`, then stamp defaults below, commit.

Anchor aliases used in code:

| Alias | Value | = blob1 + |
|---|---:|---:|
| `DAT_008277f0` | `0x200089dc` | `0` |
| alarm/DND anchor | `0x20008abc` | `0xe0` |
| sedentary base | `0x20008c5c` | `0x280` |
| menses `DAT_0082b0b8` | `0x20008c7c` | `0x2a0` |
| touch base | `0x20008a9c` | `0xc0` |

### Header / targets / time (low offsets)

| Off | Size | Field | Notes | Conf |
|---:|---:|---|---|:---:|
| `+0x00` | 1 | **magic** `0x07` | | high |
| `+0x02` | 1 | **flags** | bit4 = time-initialized (`settings_time_is_initialized`); bit2 toggled by `FUN_008276d8`; default mask `& 0xca` | high |
| `+0x08` | 1 | written in defaults path | | low |
| `+0x0c` | 1 | runtime flag | | low |
| `+0x0d` | 1 | mirrored/aux | | low |
| `+0x10` | 4 | **target_a** default `0x1388` (5000) | step-target class default | high |
| `+0x14` | 4 | **target_b** default `0x000493e0` (300000) | distance/calorie-scale default | med |
| `+0x18` | 4 | **target_c** default `0x00000bb8` (3000) | | med |
| `+0x1c` | 2 | default `0x0078` (120) | | med |
| `+0x1e` | 2 | default `0x01e0` (480) | | med |
| `+0x20..+0x23` | 4 | packed field from defaults table | `FUN_00827702` writes `+0x20..+0x23` | med |
| `+0x24..+0x27` | 4 | second defaults word | | med |
| `+0x28` | 4 | **time_extra** from setTime req byte7 | `settings_store_time_extra_field` | high |
| `+0x2c` | 1 | default `5` | | med |

### `+0x2d` feature / sensor enable bitmap (**high**)

| Bit | Mask | Meaning | Channel-A / path | Commit? |
|---:|---:|---|---|---|
| 0 | `0x01` | reserved/other (`FUN_00827638` reads) | set in defaults `\|0x6f` | defaults |
| 1 | `0x02` | **SpO2 enabled** | `0x2c` | **yes** (`settings_blob1_commit_if_changed`) |
| 2 | `0x04` | **HR auto enable** | `0x36` | RAM path |
| 3 | `0x08` | **pressure/stress enable** | `0x38` | RAM |
| 4 | `0x10` | (unused in scanned owners) | | — |
| 5 | `0x20` | **blood-sugar flag** | `0x3a/3` | RAM |
| 6 | `0x40` | set by defaults `0x6f` | | defaults |
| 7 | `0x80` | **lipids flag** | `0x3a/4` and FEE7 `0x3e` | RAM |

Default after init: `+0x2d |= 0x6f` (bits 0,1,2,3,5,6).

| Off | Size | Field | Notes | Conf |
|---:|---:|---|---|:---:|
| `+0x2e` | 1 | **sugar/lipids init sentinel** | first sugar write sets `0x1e` if zero; defaults force `0x1e` | high |

### Touch / UV

| Off | Size | Field | Notes | Conf |
|---:|---:|---|---|:---:|
| `+0xc8` | 1 | **touch/UV config** | Ch-A `0x3b` at `touch_base+8`; default `1`; `req[2]==0` gate | high |

### HR auto-measure window block (defaults)

| Off | Size | Default | Likely meaning | Conf |
|---:|---:|---:|---|:---:|
| `+0xd8` | 1 | `0x28` (40) | lo threshold | med |
| `+0xd9` | 1 | `0x78` (120) | hi threshold | med |
| `+0xda` | 1 | `1` | enable | med |
| `+0xdb` | 1 | `0x1e` (30) | interval minutes | med |
| `+0xdc` | 1 | `8` | start hour-ish | med |
| `+0xde` | 2 | `0x017c` (380) | packed end / span | med |

### DND schedule — `+0xee..+0xf3` (**high**)

Backing: `0x20008abc + 0x0e` = blob1+`0xee`. Channel-A `0x06`.

| Off | Size | Field | Notes |
|---:|---:|---|---|
| `+0xee` | 1 | **enable** | `0` off, nonzero on; wire read emits `1=on / 2=off` |
| `+0xef` | 1 | **runtime mode** | `1` force active; `2` special suppress branch; else windowed |
| `+0xf0` | 2 | **start_min** u16 LE | minute-of-day |
| `+0xf2` | 2 | **end_min** u16 LE | minute-of-day |

Write packs enable into low half of first u16 with start in high half (see `dnd_schedule_update_from_frame`).

### Alarm table — `+0xf6` count + `+0xf8` records (**high**)

See §5 below. Occupies through `+0x291` (10×`0x29`); `+0x292..+0x293` pad before sedentary.

### Sedentary — `+0x294..+0x299` (**high**)

Channel-A `0x25`/`0x26`. Times stored binary (not BCD); wire uses BCD.

| Off | Size | Field | Notes |
|---:|---:|---|---|
| `+0x294` | 1 | start_hour | 0..23 |
| `+0x295` | 1 | start_min | 0..59 |
| `+0x296` | 1 | end_hour | |
| `+0x297` | 1 | end_min | |
| `+0x298` | 1 | **weekday bitmask** | tick checks `flags & (1<<dow)`; not a simple on/off |
| `+0x299` | 1 | **interval minutes** | clamp ≤60 on write; nudge threshold |

### Menstruation mixture — `+0x29a..+0x2a9` (**high**)

16 B record; marker `0xCA`. Full consumer map in `period-data/evidence.md`.

| Off | Size | Field |
|---:|---:|---|
| `+0x29a` | 1 | sentinel `0xCA` |
| `+0x29b..+0x29d` | 3 | start_date_bcd |
| `+0x29e..+0x29f` | 2 | day_anchor u16 (`today - offset`) |
| `+0x2a0..+0x2a1` | 2 | month_anchor u16 |
| `+0x2a2..+0x2a6` | 5 | `period_data` host blob (store/echo only) |
| `+0x2a7..+0x2a9` | 3 | padding |

Blob1 ends at `+0x2af`.

### What factory / system reset does to blob1

- `FUN_0082949c` (called from system reset `FUN_008275d8`): writes **zeros** to flash slot `0x400` len `0x2b0` (wipes persisted blob1).
- `FUN_00827446`: re-inits RAM defaults + commit (used on other format paths).
- Channel-A `0xff "fff"`: runs system reset (clears user_config flash + blob1 flash + file tables) then `memset(user_config RAM, 0, 0xa4)`. **Sensor bits in blob1 are wiped with blob1 flash**, contrary to older notes that only mentioned the 164 B wipe — the 164 B wipe is *additional* RAM clear of user_config after reset.

---

## 3. user_config block — slot `0x200`, len `0xa4`

**Magic:** u32 LE **`0xa1b2c3e5`** at `+0` (not a single-byte magic).  
**Load:** `user_config_block_load_ok` — load flash→RAM, require `*(u32*)base == 0xa1b2c3e5`.  
**Init:** zero `0xa4`, write magic, commit.  
**Mirror:** `user_config_load_or_init` copies `base[+0x0d]` → `base[+0xa6]` (runtime byte **outside** the 164 B persisted span).

This block is **not** the DND/alarm/sedentary store (those live in blob1). It is a persisted **clock / session tick** block referenced as `DAT_0082cff0` / `DAT_0082780c` / `DAT_00827a74`.

### Field map

| Off | Size | Field | Role | Conf |
|---:|---:|---|---|:---:|
| `+0x00` | 4 | **magic** `0xa1b2c3e5` | load gate + init | high |
| `+0x04` | 4 | **tick_seconds** accumulator | main 1 Hz path adds delta; `% 60` gates minute work; zeroed on reset | high |
| `+0x08` | 4 | **rtc_snapshot** | refreshed from RTC counter block `+0x30` | high |
| `+0x0c` | 1 | **clock_source / rate select** | `0` → scale `0x8000`; nonzero → `32000` in RTC re-arm | high |
| `+0x0d` | 1 | **time_set_latch** | set `1` on first successful setTime path; mirrored to `+0xa6`; zeroed on reset | high |
| `+0x12` | 1 | status byte | `FUN_0082762c` reader | med |
| `+0x14` | 4 | written once in OTA-adjacent path | | low |
| `+0x15..+0xa3` | — | remainder zeroed on init/reset; few direct refs in body | needs more live/use mapping | low |
| `+0xa6` | 1 | **runtime mirror of `+0x0d`** | not in flash length `0xa4` | high |

### Factory reset (`0xff` + `"fff"`)

1. `FUN_008275d8` system reset: stop sensors/BLE, **clear user_config flash**, **zero blob1 flash**, format file tables, arm 1 s restart timer, commit zeroed user_config fields `+4/+8/+0xd`.
2. `memset(user_config RAM, 0, 0xa4)` — drops magic until next load/init path recreates it.

---

## 4. Config blob magic `0x8721bee2` (item table)

Base used by MAC paths: **`0x00801400`**.

### Header

```
+0  u32 LE  magic = 0x8721bee2
+4  u16 LE  payload_len   # bytes after the 6-byte header
+6  records...
```

`cfg_blob_magic_ok` (`0x00840724`) loads u32@0 and compares; logs `"wrong signature! Read %8X != Requried %8X"` on mismatch (legacy wording — not OTA).

### Record format (`cfg_find_item` / `cfg_upsert_items_and_rewrite_blob`)

```
u16 LE item_id
u8     len
u8     value[len]
u8     mirror_or_compare[len]   # second copy; find matches value vs query's compare ptr
```

Record size = `3 + 2*len`.  
Scan starts at blob `+6`, stops when cursor ≥ `6 + payload_len` or cursor ≥ ~`0x03fa`.

Upsert descriptor (12 B per item in caller array):

```
+0  u16 item_id
+2  u8  len
+4  ptr value
+8  ptr mirror
```

`cfg_upsert` rebuilds blob (preserve existing, replace matched ids, append new), then `cfg_write_to_flash_preserve_sector` (keeps 0x400 prefix + 0x800 suffix around changed 4 KiB sector).

### Field-ids used in H59MA v14 body

| item_id | len | Meaning | Callers |
|---:|---:|---|---|
| **`0x33`** | **6** | **BLE MAC** | `cfg_update_mac_item` (Ch-B TLV2, Ch-A `0x81`, GAP register sync); `cfg_read_mac_item` |

Static xref scan: **only item `0x33`** is constructed and passed into `cfg_find_item` / `cfg_upsert` in this body. The table format is generic; no other item_ids are referenced by immediate loads in the app image.

### Overlap with Ch-B `0x5a` / blob0

| Surface | MAC bytes | Enable | Persist |
|---|---|---|---|
| blob0 `+0xce` | working override | `+0xd6[3:2]==1` | blob0 commit |
| cfg item `0x33` | sector config | always via upsert | cfg blob rewrite |

Write paths that keep both coherent: TLV id 2 store, `0x81`, GAP register when override differs from item `0x33`. Subcmd `0x5a/4` clears blob0 only → item `0x33` can go stale until next MAC update.

---

## 5. Alarm records — 10 × `0x29` + Channel-B `0x2c`

### Module init

- `alarm_module_init` `0x0082ac50`: if count@`blob1+0xf6` > 10, zero `0x19c` bytes from count; then normalize.
- `alarm_defaults_normalize` `0x0082ac72`: for each of 10 slots, if **enable/sentinel byte `== 0xFF`**, install default **08:15**, all 7 weekdays `=1`, set record byte0 bit7.

### Storage (blob1)

| Off | Size | Field |
|---:|---:|---|
| `+0xf6` | 1 | **count** (0..10) |
| `+0xf7` | 1 | side flag (`FUN_00827a00` / adjacent) |
| `+0xf8 + i*0x29` | `0x29` | record `i` (i=0..9) |

Working copy helpers `FUN_0082a9c2` / `FUN_0082a9b0` memcpy `0x19c` bytes from/to `anchor+0x16` (`0x20008abc+0x16` = count + records).

### Internal record layout (`0x29` bytes) — **high**

| Off | Size | Field |
|---:|---:|---|
| `+0x00` | 1 | **len_flags**: bits6..0 = compact length including 4-byte wire header; bit7 = slot-valid / matched-existing flag used on import |
| `+0x01` | 1 | **enable** (`0`/`1`); `0xFF` = uninitialized → defaulted |
| `+0x02` | 1 | **hour** binary 0..23 |
| `+0x03` | 1 | **minute** binary 0..59 |
| `+0x04..+0x0a` | 7 | **weekday[7]** each `0`/`1` (bit i of wire flags) |
| `+0x0b..+0x28` | ≤`0x1e` | **label** bytes; max label length clamped to `0x1e` on write |

Default when `+0x01 == 0xFF`: `+0x01=0`, hour=`8`, min=`15`, weekdays all `1`, `+0x00 \|= 0x80`.

### Channel-B `0x2c` wire format — **high**

Handler: `channel_b_handle_alarm_read_write` `0x0082f8ec`.

**Read** `payload[0]==1` → response cmd `0x2c`:

```
[0x01][count]{ rec }*
rec = [len][flags][minuteOfDay u16LE][label[len-4]]
```

Encode:

- `len = internal[0] & 0x7f` (includes 4-byte header)
- `flags bit7 = (internal[1] != 0)`
- `flags bits0..6 = (internal[4+i] != 0) << i` for i=0..6
- `minuteOfDay = hour*60 + minute`
- label from `internal+0x0b`, length `len-4`

**Write** `payload[0]==2`:

```
[0x02][count≤10]{ rec }*
```

Decode reverse of above; clamp label to `0x1e`; match existing slot by hour/min to preserve bit7 via `FUN_00827a0e`; `FUN_0082a9b0` stores table; ack `[0x02]`.

### Channel-A `0x23`/`0x24`

Not in H59MA v14 Channel-A handler inventory. Host must use **Channel-B `0x2c`**. (Ch-B itself NAKs cmds `0x23`/`0x24` with code `2`.)

---

## 6. Confidence / open tails

| Item | Status |
|---|---|
| blob0 TLV/string/MAC/session_mode | high |
| blob1 `+0x2d` bits, DND, sedentary, menses, touch | high |
| alarm `0x29` + Ch-B compact | high |
| cfg item table format + id `0x33` | high |
| user_config magic + tick/rtc/latch | high |
| blob1 `+0x10..+0x28` exact unit labels (steps vs kcal) | med — defaults numeric only |
| blob1 `+0xd8` HR window field units | med — matches APK HR setting shape |
| user_config `+0x15..+0xa3` bulk | low — zeroed, few refs |
| cfg item_ids other than `0x33` | none in body; may exist pre-provisioned in flash |

Reproduce:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  firmwares/_re/v14/body.bin
# blob0 load @ body 0x30e0, blob1 commit @ 0x3056, user_cfg @ 0x312a
# alarm init @ 0x4850, Ch-B alarm @ 0x94ec, cfg_find @ 0x1a7e0
```

## Resolution: `blob1 + 0x2d` Feature Bitfield (2026-07-18)

Cross-reference of `settings-maps`, `vendor-high-audit`, `health-measure`, and
`GHIDRA_DECOMPILATION.md` §3.12/§10.2 yields the following two-evidence-line labels
for the shared feature byte at `DAT_008277f0 + 0x2d`, read/written by handlers
`0x2c` (SpO2), `0x36` (HR), `0x38` (pressure), `0x3a` subcmds (sugar/lipids):

| Bit | Mask | Name | Gates | Evidence |
|---|---|---|---|---|
| 0 | `0x01` | unknown | reserved/unclaimed | `settings-maps:126`, GHIDRA §3406 |
| 1 | `0x02` | `spo2_enabled` | `0x2c` SpO2 enable/disable path | `settings-maps:127`, GHIDRA §3409 |
| 2 | `0x04` | `hr_auto_enabled` | HR auto-measure path tied to `0x36` | `settings-maps:128`, GHIDRA §3411 |
| 3 | `0x08` | `pressure_enabled` | `0x38` pressure setting path | `settings-maps:129`, GHIDRA §3413 |
| 4 | `0x10` | unknown | unused — no named owner | `settings-maps:130`, GHIDRA §3412 |
| 5 | `0x20` | `sugar` | `0x3a` subcmd `0x03` blood-sugar feature | `settings-maps:131`, GHIDRA §2050 |
| 6 | `0x40` | unknown | set in default `0x6f` bitset; no named owner | `settings-maps:132`, GHIDRA §3414 |
| 7 | `0x80` | `lipids` | `0x3a` subcmd `0x04` / legacy `0x3e` | `settings-maps:133`, GHIDRA §2051 |

Default factory value: `0x6f` = bits 0,1,2,3,5,6 set (spo2+hr+pressure+sugar+lipids plus the two unknowns).

Note: the vendor/high `0xa0` status frame is a *response* frame (status payload
with battery, mode markers, blob0 fields) — separate from this feature bitfield.
