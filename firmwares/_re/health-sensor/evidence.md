# H59MA v14 Health Event Bus, Live HR, SpO2, Gsensor & Sensor Bus

Firmware: `firmwares/_re/v14/body.bin`  
Base: flash `0x00826400` (body offset = flash − `0x00826400`)

Related:

- `firmwares/_re/health-measure/evidence.md` — Channel-A `0x69`/`0x6a`/`0x2c` entry points (radare2)
- `firmwares/_re/bp-slot-encoding/evidence.md` — BP auto mask `4`, history slot layout
- `firmwares/GHIDRA_DECOMPILATION.md` §7 / §3.10 / §3.13 / §8.5

Tools: Ghidra decompile + body.bin constant recovery.

## Summary

| Claim | Confidence |
|---|---|
| Health event bus: start=`{0x10003, mask}`, stop=`{0x20003, mask}` via `FUN_008273d0` | **High** |
| `health_module_event_dispatch` cases 0..3 = nop / start_mask / stop_mask / nop | **High** |
| Sensor mask bit table from mode→mask + auto-measure callers | **High** for listed bits |
| Live `0x69` frame layouts per mode/tick phase | **High** static packing |
| `0x6a` result frame packing | **High** |
| SpO2 auto uses mask `0x80` + 1 s timer, not Channel-A `0x2c` cadence | **High** |
| Channel-A `0x2c` only reads/writes enable bit in settings blob1 | **High** |
| Body temp is pure stub (init empty, getter always 0); live path may PRNG-fill | **High** |
| Blood sugar is synthetic from SpO2-ish input, not a real sensor | **High** |
| LIS3DH path uses sensor-bus device `0x19` regs matching ST map | **High** |
| Sensor-bus device IDs: `0x19`/`0x1f`/`0x20` accel families, `0x33` motor | **High** |
| Step counts come from `sport_state_*` / `vc_SportMotion_Int`, fed by gsensor ring | **Medium** (library boundary) |

---

## 1. Health event bus

### Post helpers

```c
// flash 0x0083371e
void health_post_start_measure_event(u32 mask) {
  u32 msg[2] = { 0x00010003, mask };   // sub=1 in upper half of word0
  FUN_008273d0(msg, 0x17c);            // queue id / msg size constant
}

// flash 0x00833704
void health_post_stop_measure_event(u32 mask) {
  u32 msg[2] = { 0x00020003, mask };   // sub=2
  FUN_008273d0(msg, 0x174);
}
```

`FUN_008273d0` posts into the app event queue when the queue handle at
`*(DAT_008273f4+8)` is non-null. The consumer is
`health_module_event_dispatch`.

Event word packing (same convention as other modules):

| Word | Field |
|---|---|
| `msg[0]` low 16 | module id `0x0003` (health) |
| `msg[0]` high 16 | sub-command (1=start, 2=stop; 0/3 exist as no-ops) |
| `msg[1]` | sensor **mask** (bitfield) |

### `health_module_event_dispatch` (`0x00833770`) — full case table

```c
void health_module_event_dispatch(u32 param1, u16 param2 /*mask*/) {
  u16 sub = param1 >> 16;
  switch (sub) {
    case 0: FUN_0083376e(); return;          // empty nop (reset stub)
    case 1: health_start_sensor_mask(param2); return;
    case 2: health_stop_sensor_mask(param2);  return;
    case 3: FUN_0083376c(); return;          // empty nop (read stub)
    default:
      // assert log qc_code_app_module.h line 0x1ac
  }
}
```

| Sub | Symbol | Effect |
|---:|---|---|
| 0 | `FUN_0083376e` | **No-op** (`bx lr`) |
| 1 | `health_start_sensor_mask` | OR mask into active set; power PPG/sensor algo |
| 2 | `health_stop_sensor_mask` | AND-clear mask; if zero → power-down path |
| 3 | `FUN_0083376c` | **No-op** (`bx lr`) |

### `health_start_sensor_mask` (`0x00837b96`)

State base: `DAT_00837d30` → SRAM `0x0020c268` (active mask at `+0`).

```text
alert_cancel_active()
if (active_mask != 0) {
  if (active_mask & 0x40) return;          // bit6 sticky lock?
  if ((new & 0xa0) && !(active & 0xa0)) {
    // SpO2 family (bits 0x20|0x80) transition into PPG path:
    // mode byte=1, period=0x78, FUN_0083f3a4/FUN_0083ab60/FUN_008374b4
  }
  active |= new;
  return;
}
// first start from idle:
if (!sensor_hw_ready()) { set pending flags; return; }
if ((new & 0xa0) == 0) {
  if (new == 0x40 || new == 0x800) driver_mode = 7;
  else driver_mode = 0;
} else {
  driver_mode = 1;                         // SpO2-family
}
period = 0x78; FUN_008374b4(...);          // kick PPG/HR algo frontend
active |= new;
```

### `health_stop_sensor_mask` (`0x00837c4e`)

```text
active &= ~mask
if (active == 0) {
  driver_mode = 5; FUN_008374b4(...);      // full stop
  clear flags; timer_stop_and_delete(...)
} else if ((mask & 0xa0) && !(active & 0xa0)) {
  // leaving SpO2 family while other bits remain
  FUN_008369a4(0); driver_mode = 0; FUN_008374b4(...)
}
```

`FUN_008374b4` is the PPG/HR algorithm frontend (`switch` on driver mode 0..5).

---

## 2. Complete sensor bitmask table

Bits proven by **mode→mask** mapping in `health_handle_start/stop_measure`
and by **auto-measure starters**. Values are OR-able.

| Bit mask | Name | Proven by | Notes |
|---:|---|---|---|
| `0x0001` | **HR** | modes 1/6/0x0D default; continuous mode-6 | `heart_rate_current_bpm()` |
| `0x0002` | **HR one-shot / sample** | `FUN_008337fa` | Short sample; used by internal callers |
| `0x0004` | **BP auto** | `FUN_00834426` | See `bp-slot-encoding/evidence.md` |
| `0x0010` | **Interval HR / pressure-adjacent auto** | `FUN_00833dac` / `FUN_00833eac` | Gated by `FUN_00827638` enable |
| `0x0020` | **SpO2 manual session** | mode `0x03`, `0x0E` | `spo2_current_value()` on stop |
| `0x0040` | **Factory / special** | factory path `0x00828018` | Treated specially with `0x800` in start_mask |
| `0x0080` | **SpO2 auto-measure** | `FUN_00833af8` | Periodic path; pairs with `0x20` as family `0xa0` |
| `0x0100` | **HRV** | mode `0x0A`; auto `FUN_00834764` | `hrv_current_value()` |
| `0x0200` | **Pressure / stress** | mode `0x08`; auto `FUN_008345ce` | `pressure_current_value()` |
| `0x0400` | **Blood sugar** | mode `0x09` | Synthetic; `blood_sugar_current_value()` |
| `0x0800` | **Factory one-shot** | `0xa1` sub `0x04` (see §3 / factory) | Paired with `0x40` in start_mask |
| `0x1000` | **Body temperature** | mode `0x0B` | **Stub getter always 0** |
| `0x2000` | **Realtime continuous HR** | Channel-A `0x1e` | 60 s countdown path |
| `0x1301` | Composite multi | mode `0x0C` (`DAT_0082c57c`) | `HR\|HRV\|pressure\|temp` = `1\|0x100\|0x200\|0x1000` |
| `0x1701` | Composite timer stop | modes `0x0D`/`0x0E` stop side (`DAT_0082c580`) | `HR\|HRV\|pressure\|sugar\|temp` |

### Mode (`0x69` type) → mask

| Type (SDK name) | Mode | Start mask | Stop / value source |
|---|---:|---:|---|
| HEARTRATE | `0x01` | `0x0001` | `heart_rate_current_bpm` |
| BLOODPRESSURE | `0x02` | `0x0001` (+ synthetic sys/dia) | HR + `FUN_00834092` |
| BLOODOXYGEN | `0x03` | `0x0020` | `spo2_current_value` |
| FATIGUE | `0x04` | (falls to `0x0001`) | HR fallback |
| HEALTHCHECK | `0x05` | `0x0001` (+ synthetic sys/dia like BP) | HR + `FUN_00834092` |
| REALTIMEHEARTRATE | `0x06` | `0x0001` (sub machine) | continuous sub-state |
| ECG | `0x07` | **no case** → `0x0001` | no ECG path on v14 |
| PRESSURE | `0x08` | `0x0200` | `pressure_current_value` |
| BLOOD_SUGAR | `0x09` | `0x0400` (+ `FUN_00834862` clear) | `blood_sugar_current_value` |
| HRV | `0x0A` | `0x0100` | `hrv_current_value` |
| BODY_TEMPERATURE | `0x0B` | `0x1000` | stub → 0 / PRNG fill in live path |
| multi / health combo | `0x0C` | `0x1301` | HR+HRV+pressure+temp+sys/dia |
| (extended) | `0x0D` | `0x0001` | special timer duration path |
| (extended SpO2) | `0x0E` | `0x0020` | special timer duration path |

---

## 3. Live HR path — timers and frame layouts

### Timers

| Name | Period | Callback | Role |
|---|---:|---|---|
| `m_heart_rate_timer_id` | 500 ms | `health_measure_timer_cb` `0x0082b8de` | Session tick; `state[+0xc]++` |
| `hr_realtime_test_id` | 1000 ms | (realtime path) | Created at init; used with `0x1e` |

```c
// health_measure_timer_cb
state.tick++;
if (mode != 6) FUN_0082b298();   // generic per-mode progress/result
else           FUN_0082b6d4();   // continuous mode-6 sub-machine
```

Session state at `DAT_0082c578` / `DAT_0082b4fc` → SRAM `0x00209f2c`:

| Off | Field |
|---:|---|
| +2 | once-flag for BP synthetic |
| +3..+5 | mode-6 sub-state counters |
| +7 | current mode |
| +8 | current sub (mode 6) |
| +0xA | duration param u16 (clamped ≥10) |
| +0xC | tick counter (500 ms units) |
| +0x10 | timer handle (500 ms) |
| +0x24 | mode-6 float HR cache |

### Channel-A `0x69` — start ACK (handler `health_handle_start_measure`)

| Byte | Busy path | Accept path |
|---:|---|---|
| 0 | `0x69` | `0x69` |
| 1 | req mode | stored mode |
| 2 | `0x01` (busy) | `0x00` (accepted) |
| 3..14 | 0 | 0 |
| 15 | checksum8 | checksum8 |

Busy gate: `health_sensor_session_is_active()` (`*DAT_00828b2c == 1`).

### Channel-A `0x69` — live progress / value (timer `FUN_0082b298`)

Common header always:

| Byte | Content |
|---:|---|
| 0 | `0x69` |
| 1 | current mode |
| 15 | additive checksum of bytes 0..14 |

#### Phase A — early ticks (`1 ≤ tick < 0x33` = 51)

| Byte | Content |
|---:|---|
| 2 | `0x00` |
| 3 | `0x00` |
| 4..5 | `0` |
| 6..7 | progress u16 LE from sensor state `DAT_00837d30+6` (`FUN_00837aee`) |
| 8..14 | `0` |

#### Phase B — value ticks (`0x33 ≤ tick < 0x3c`)

| Mode | [2] | [3] primary | [4] | [5] | [6..7] | [8] | [9] | [10] |
|---:|---|---|---|---|---|---|---|---|
| 1 (HR) | 0 | bpm | 0 | 0 | progress | 0 | 0 | 0 |
| 2 / 5 (BP/health) | 0 | bpm | **sys** | **dia** | progress | 0 | 0 | 0 |
| 3 (SpO2) | 0 | spo2% | `1` when ready | 0 | progress | 0 | 0 | 0 |
| 8 (pressure) | 0 | stress | 0 | 0 | progress | 0 | 0 | 0 |
| 9 (sugar) | 0 | sugar | 0 | 0 | progress | 0 | 0 | 0 |
| 0x0A (HRV) | 0 | hrv | 0 | 0 | progress | 0 | 0 | 0 |
| 0x0B (temp) | 0 | temp† | 0 | 0 | progress | 0 | 0 | 0 |
| 0x0C (multi) | 0 | bpm | hrv | pressure | progress | temp† | **sys** | **dia** |
| other | 0 | bpm | 0 | 0 | progress | 0 | 0 | 0 |

† Body-temp getter is stub 0; live path substitutes PRNG when raw &lt; `0x96`.

HR validity: bpm kept only if `0x28 ≤ bpm ≤ 0xDC` (40–220); else 0 then
fallback PRNG `(r%4)+0x5f` (95–98) except modes 0x0A/0x0B.

HRV out-of-range (`0` or outside 30..50): PRNG `(r%0x14)+0x1e` (30–49).  
Pressure out-of-range (outside 20..65): same PRNG 30–49.

#### Phase C — late ticks (`tick ≥ 0x3c` = 60)

Auto-stop for most modes: `health_post_stop_measure_event(mask)` + cancel timer.  
Modes 0x0A / 0x0C emit one more rich frame (same multi layout) before stop.

#### Mode 6 continuous (`FUN_0082b6d4`)

| Byte | Content |
|---:|---|
| 0 | `0x69` |
| 1 | `0x06` |
| 2 | `1` (streaming sample) or `2` (settled/end-of-burst) |
| 3 | bpm (± PRNG noise `r%3 − 1` applied in float domain) |
| 4..14 | 0 |
| 15 | checksum |

Sub `req[2]`: `1` start, `2` cancel timer, `3` refresh timer, `4` stop HR mask.

### Channel-A `0x6a` — stop / final result (`health_handle_stop_measure`)

Request must echo current mode in `req[1]` or handler returns without reply.

| Byte | Simple modes (1,3,8,9,0x0B,…) | Mode `0x0C` multi |
|---:|---|---|
| 0 | `0x6a` | `0x6a` |
| 1 | mode | `0x0C` |
| 2 | **primary value** | `0` |
| 3 | `0` | **bpm** |
| 4 | 0 | **hrv** |
| 5 | 0 | **pressure** |
| 6..7 | 0 | 0 |
| 8 | 0 | **temp†** |
| 9 | 0 | **sys** (`FUN_00834092`) |
| 10 | 0 | **dia** |
| 11..14 | 0 | 0 |
| 15 | checksum | checksum |

Mode mapping for stop mask / value:

| Mode | Stop mask | Primary value (`byte2` or multi) |
|---:|---:|---|
| 3 | `0x20` | SpO2 |
| 9 | `0x400` | blood sugar |
| 0x0B | `0x1000` | body temp stub |
| 0x0C | `0x1301` | multi pack |
| else | `0x1` (or mode-specific) | HR bpm |

Early stop guard: if `tick < 0x3c` the handler still stops the mask; if
`tick < 0x32` it **returns without** a result frame (measurement too short).

---

## 4. SpO2 auto-measure (`0x2c` + mask `0x80`)

### Channel-A `0x2c` — enable bit only (`channel_a_handle_spo2_setting` `0x0082d1c2`)

| Sub | Action |
|---:|---|
| `0x01` | read enable → `rsp[2] = (blob1[+0x2d] & 3) >> 1` |
| `0x02` | write enable bit1 of blob1[+0x2d]; commit blob1 if changed |

**No cadence timer, no result notify.** Earlier `health-measure/evidence.md`
note that body `0x6e0c` is a 60 s / `0x2000` path is the **`0x1e` realtime HR**
handler (`0x0082d20c`), not SpO2.

### Auto path (when enable=1)

| Step | Function | Detail |
|---|---|---|
| Schedule | `FUN_00833af8` | If enable && session state ok && not sport && not busy → `health_post_start_measure_event(0x80)` + 1000 ms timer |
| Tick | `FUN_00833a94` | `tick++`; ticks 3..14 abort if sensor idle (`FUN_00837ac8==0`); if value ready → store + stop; if tick&gt;0x40 and still 0 → PRNG spo2 |
| Store | `FUN_00833a24` | Clamp: if &lt;91 → PRNG `93..96`; if &gt;100 → 100; write `*activity_state_ptr` |
| History | `FUN_00833a56` | Update day/hour min/max; `channel_a_send_device_notify(3)` |
| Read current | `spo2_current_value` | returns `*activity_state_ptr` |

No dedicated SpO2 history Channel-A stream beyond device-notify `0x73` type 3
and the live `0x69` mode-3 session path.

---

## 5. LIS3DH / gsensor family

### Entry

`lis3dh_accel_dispatch` (`0x00833334`): only sub=0 accepted →
`gsensor_service_state_machine` (`0x00832dd6`). Other sub → assert log
`qc_code_app_module_g`.

### Init (`gsensor_init_timers_and_probe` `0x008332dc`)

1. `gsensor_probe_or_recover`
2. Create `gsensor_read_timer_id` (2000 ms) and `gsensor_shake_flag_timer_id` (2000 ms, one-shot style)
3. `FUN_00843d48` / `FUN_00843fbc` / `FUN_0084410c` / `FUN_00843f88` — motion-algorithm defaults (thresholds, sensitivity)
4. Clear startup flag

### Chip detect (`gsensor_detect_chip_id` `0x008324aa`)

| WHO_AM_I / id | Bus device | Notes |
|---|---|---|
| `0x11` (fallback) | `0x19` path A | LIS3DH-like (string `lis3dh_spi.c`) |
| `0x28` `'('` | `0x19` path A | LIS2DH/LIS3DH family WHO_AM_I |
| `0x23` `'#'` | `0x1f` | Alternate IMU |
| `0x44` `'D'` | `0x19` path B | Alternate |
| `0x48` `'H'` | `0x20` | Alternate |

### LIS3DH-like active config (`gsensor_apply_active_config`)

For id `0x11` / `0x28` via `sensor_bus_write_reg_0x19_a`:

| Reg | Value | ST LIS3DH meaning |
|---:|---:|---|
| `0x22` | `0x00` | CTRL_REG3 |
| `0x38` | `0x00` | then FIFO setup |
| `0x20` | `0x37` | CTRL_REG1: ODR + XYZ enable |
| `0x23` | `0x90` | CTRL_REG4: BDU + FS |
| `0x24` | `0x40` | CTRL_REG5: FIFO_EN |
| `0x2e` | `0x00` then `0x80` | FIFO_CTRL: mode |

Click/shake setup (`FUN_00832bfc`) also programs:

| Reg | Value | Role |
|---:|---:|---|
| `0x21` | `0x04` | CTRL_REG2 |
| `0x3a` | `0x05` | CLICK_CFG |
| `0x3b` | `0x7f` | CLICK_THS |
| `0x3c` | `0x02` | TIME_LIMIT |
| `0x38` | `0x15` | CLICK_SRC / related |
| `0x22` | `0x80` | INT1 click enable |

Disable path (`FUN_00832d8a`): `0x22=0`, `0x38=0`, `0x20=0`.

### FIFO poll → ring (`gsensor_poll_fifo_into_ring` `0x008325c0`)

LIS3DH path:

1. Read `0x2f` FIFO_SRC → sample count (`& 0x1f`)
2. For each sample: read `0xa7` (auto-increment OUT_X_L multi-read), take 6 axis bytes
3. Append into circular ring at `chip_state+0x28`, capacity `0x1ec` bytes (82×6)
4. Empty-read streak ≥10 → `gsensor_probe_or_recover` + reconfig

### Service state machine flags (`DAT_00833188`)

| Off | Role |
|---:|---|
| +0x1a | active |
| +0x1b | ring valid / feed enable |
| +0x1c | aux |
| +0x1d | **request enable** → apply config |
| +0x1e | **request disable** |
| +0x1f | **reconfig** (restart 800 ms timer) |
| +0x20 | **shake/click service** branch (`FUN_008322e0` + `FUN_00832bfc`) |
| +0x24 | ring fill length |
| +0x26 | saved length |

### Step counting path

```text
gsensor_poll_fifo_into_ring
  → FUN_00827124 (kick motion consumer if registered)
  → FUN_00832f1e exports XYZ triples from ring
  → vc_SportMotion_Int library (string @ flash 0x00847914)
  → sport_state_get_steps / distance / calories  (SRAM via DAT_00831d94)
  → today totals: Channel-A 0x48, detail history 0x43, Channel-B 0x2a
```

`sport_state_get_steps` @ `0x00831b12` reads the live step counter. Hourly
activity history uses 12-byte slots with steps at `+4` u16.

### Shake / raise-to-wake / touch

- `gsensor_shake_flag_timer_id` — debounce timer for shake flag clear
- Click/INT programming above = hardware shake/double-tap path on LIS3DH INT
- Raise-to-wake / wrist-turn is **not** a separate named function; it is folded
  into motion-algo defaults (`FUN_00843fbc` thresholds 0x50..0xFA / 0x14..0xDC,
  `FUN_0084410c` mode, `FUN_00843f88` sensitivity 10..40) registered at gsensor
  init. Touch-screen wakeup is a separate DLPS/GPIO path (see GHIDRA §6).

---

## 6. Sensor bus

### Framing

```c
// write: device_id, reg, payload[len]
sensor_bus_write_payload(device, reg, data, len) {
  buf = alloc(len+0xb);
  buf[0] = reg;
  memcpy(buf+1, data, len);
  FUN_00833594(device, buf, len+1);   // bus transaction w/ busy-wait
  free(buf);
}

// read: device_id, reg, out, len
sensor_bus_read_payload(device, reg, out, len)
  → FUN_0083365a(device, &reg, 1, out, len)
```

All `sensor_bus_*_reg_*` wrappers take a **mutex** (`func_0x000133f4` /
`func_0x0001341c`) with 100 ms timeout around the payload call.

### Device ID map

| Device ID | Wrapper family | Physical role |
|---:|---|---|
| `0x19` | `sensor_bus_{read,write}_reg_0x19_a/b` | **Accelerometer** primary (LIS3DH-like + variant `'D'`); also **motor duration pattern** mode `'D'` (see GHIDRA motor section) |
| `0x1f` | `…_reg_0x1f` | **Alternate IMU** (`'#'`); also **motor pulse pattern** mode `'#'` |
| `0x20` | `…_reg_0x20` | **Alternate IMU** (`'H'`) |
| `0x33` | `…_reg_0x33` | **Motor / vibrator** control (many UI alert callers `0x00834a98`…) |

`0x19_a` vs `0x19_b` share the same device id and payload path; they are parallel
helpers used by different chip branches (identical mutex + `sensor_bus_*_payload(0x19,…)`).

Low-level transfer: `FUN_00833594` / `FUN_0083365a` bit-bang/SPI through
`FUN_008339f2` + `FUN_00838c5e` / `FUN_00838d32` with busy polls on status bits
`4` and `0x20`.

---

## 7. Blood sugar & body temperature stubs

### Body temperature — proven no-op

```c
// 0x0082acf4
void body_temperature_metric_init_stub(void) { return; }

// 0x0082acf6
u32 body_temperature_current_value_stub(void) { return 0; }
```

`health_metrics_init` still calls the init stub. Live `0x69` mode `0x0B` and
multi mode `0x0C` **display** a non-zero byte only because the timer path
PRNG-fills when the stub returns 0. There is **no sensor, no history table,
no storage**.

### Blood sugar — synthetic, not a sensor

```c
// init 0x0083486a: default scale word 0x46 if sentinel -1
// clear 0x00834862: *current = 0
// current 0x0083485c: return *DAT_00834880

// FUN_008347fc: synthesise from input (often SpO2-related)
//   maps param into a base, mixes with DAT scale, adds prng%10
```

Mode `0x09` start clears the current value then starts mask `0x400`. The value
emitted on `0x69`/`0x6a` is the synthetic result, **not** a glucometer reading.
Settings bit for sugar exists (`settings_set_sugar_flag_ram` on blob1 `+0x2d[5]`)
but no hardware path was found.

### SpO2 algorithm presence

String `spo2_VC30F_S_int_limit_ed01` + real mask `0x20`/`0x80` + store path
indicate SpO2 **is** implemented (PPG algorithm), unlike sugar/temp.

---

## 8. Key addresses

| Symbol | Flash | Body |
|---|---|---|
| `health_post_start_measure_event` | `0x0083371e` | `0xd31e` |
| `health_post_stop_measure_event` | `0x00833704` | `0xd304` |
| `health_module_event_dispatch` | `0x00833770` | `0xd370` |
| `health_start_sensor_mask` | `0x00837b96` | `0x11796` |
| `health_stop_sensor_mask` | `0x00837c4e` | `0x1184e` |
| `health_handle_start_measure` | `0x0082c2f4` | `0x5ef4` |
| `health_handle_stop_measure` | `0x0082c1e2` | `0x5de2` |
| `health_measure_timer_cb` | `0x0082b8de` | `0x54de` |
| `FUN_0082b298` (live 0x69 packer) | `0x0082b298` | `0x4e98` |
| `FUN_0082b6d4` (mode-6 packer) | `0x0082b6d4` | `0x52d4` |
| `channel_a_handle_spo2_setting` | `0x0082d1c2` | `0x6dc2` |
| `channel_a_handle_realtime_heart_rate` | `0x0082d20c` | `0x6e0c` |
| SpO2 auto start / tick / store | `0x00833af8` / `0x00833a94` / `0x00833a24` | `0xd6f8` / `0xd694` / `0xd624` |
| `lis3dh_accel_dispatch` | `0x00833334` | `0xcf34` |
| `gsensor_service_state_machine` | `0x00832dd6` | `0xc9d6` |
| `gsensor_poll_fifo_into_ring` | `0x008325c0` | `0xc1c0` |
| `gsensor_apply_active_config` | `0x0083232a` | `0xbf2a` |
| `gsensor_detect_chip_id` | `0x008324aa` | `0xc0aa` |
| `sensor_bus_write_payload` | `0x0083361c` | `0xd21c` |
| `sensor_bus_read_payload` | `0x008336e8` | `0xd2e8` |
| `body_temperature_*_stub` | `0x0082acf4` / `0x0082acf6` | `0x48f4` / `0x48f6` |
| `blood_sugar_*` | `0x0083486a` / `0x0083485c` / `0x00834862` | `0xe46a` / `0xe45c` / `0xe462` |
| mask constants `0x1301` / `0x1701` | `0x0082c57c` / `0x0082c580` | `0x617c` / `0x6180` |

---

## 9. Commands

```sh
# Ghidra
decompile 0x0083371e 0x00833704 0x00833770 0x00837b96 0x00837c4e
decompile 0x0082c2f4 0x0082c1e2 0x0082b8de 0x0082b298 0x0082b6d4
decompile 0x0082d1c2 0x00833af8 0x00833a94 0x00833a24
decompile 0x00833334 0x00832dd6 0x008325c0 0x0083232a 0x008324aa
decompile 0x0083361c 0x008336e8 0x00831f18 0x00837166
decompile 0x0082acf4 0x0082acf6 0x0083486a 0x008347fc

# body.bin mask immediates at BL sites to health_post_start_measure_event
# (see script in this RE session — 17 call sites, masks
#  1,2,4,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x1000,0x2000,0x1301)
```

---

## 10. Doc update recommendations

### `GHIDRA_DECOMPILATION.md` §7

Replace thin §7.1/§7.2 with full case table, bitmask, sensor-bus device map,
and pointers to this evidence file.

### `PROTOCOL.md` §4.3 health

- Expand `0x69`/`0x6a` response layouts (phase A/B/C + multi mode `0x0C`)
- Clarify `0x2c` = enable only; auto SpO2 is internal mask `0x80`
- Note body-temp stub + blood-sugar synthetic
- Keep ECG/PPG dedicated opcodes as resolved-negative

## Open / capture still useful

1. Wall-clock scheduler that invokes SpO2/HRV/pressure auto starters
2. Exact clinical meaning of synthetic sugar units
3. Live cuff correlation for `0x69` sys/dia (still synthetic from HR)
4. Full `vc_SportMotion_Int` step algorithm internals (vendor lib)
5. Which UI gesture maps to shake vs raise (thresholds only, no names)
