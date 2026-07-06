# H59MA v14 Health-Measurement Notify Paths — radare2 Evidence

Scope: `firmwares/_re/v14/body.bin`. Offsets are **body** offsets; absolute
flash address = `0x826400 + body_offset`.

Common invocation:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
```

## Summary

Static radare2 work confirms the live heart-rate / health-session notify opcode
and maps the sensor-session state machine that PROTOCOL.md §8.5 left as
"needs live capture". Key results:

1. **Live health-session notify opcode is `0x69` on Channel A.**
   The same opcode is used for the `StartHeartRateReq` request and for
   unsolicited live-value frames pushed by the 500 ms / 1000 ms HR timers.
2. **ECG (mode `0x07`) is not implemented on H59MA v14.** The `0x69`
   start handler explicitly dispatches modes `0x03, 0x09, 0x0B, 0x0C, 0x0D,
   0x0E, 0x06`; mode `0x07` falls through to the generic HR-mode-1 fallback,
   matching PROTOCOL.md §8.5.
3. **PPG real-time streaming is not a `0x69` mode.** The only PPG/SpO2-related
   Channel-A handler is opcode `0x2c`, which enables/disables periodic SpO2
   auto-measurement (cadence stored as `0x3c` with an ~8 s timer tick).
4. **`0x6a`** is the session stop / result opcode, paired with `0x69`.

## Heart-rate timer setup

Timer-create function `app_timer_create` is the ROM routine at
`0xff7ed234`. The two HR timers are created at body `0x54fa`:

```text
0x000054fa  push {r2, r3, r4, lr}
0x0000550a  adr r1, 0x1b8                ; "m_heart_rate_timer_id"
0x00005510  bl 0xff7ed234                ; interval = 0x1f4 (500 ms)
0x00005520  adr r1, 0x1bc                ; "hr_realtime_test_id"
0x00005526  bl 0xff7ed234                ; interval = 0x3e8 (1000 ms)
```

Callback literals:

| Timer | Literal | Callback code addr | Body offset |
|---|---|---|---|
| `m_heart_rate_timer_id` | `0x82b8df` | `0x82b8de` | `0x54de` |
| `hr_realtime_test_id` | `0x82b259` | `0x82b258` | `0x4e58` |

## Live notify frame builder (body `0x4e98`)

`pd 120 @ 0x4e98` shows the 500 ms tick callback building a Channel-A frame
with opcode `0x69`:

```text
0x00004e9c  bl 0x116c8                   ; sample/check sensor
0x00004ea0  movs r7, 0x69                ; opcode 'i'
...
0x00004ec4  strb r7, [sp]                ; frame[0] = 0x69
0x00004ec6  ldrb r0, [r5, 7]
0x00004ec8  strb r0, [sp, 1]             ; frame[1] = current mode
0x00004eca  movs r0, 1
0x00004ecc  strb r0, [sp, 2]             ; frame[2] = 0x01
0x00004ece  movs r0, 0
0x00004ed0  strb r0, [sp, 3]             ; frame[3] = 0x00
...
0x00004edc  bl 0x87dc                    ; enqueue 16-byte Channel-A frame
```

`0x87dc` is the shared Channel-A notify enqueue function. After defining it
with `af @ 0x87dc`, `axt @ 0x87dc` lists every caller; the only timer-driven
health caller is this `0x4e98` path (and the alternate mode-6 path at
`0x52d4`).

## `0x69` start handler — mode dispatch

Both Channel-A and the vendor/high dispatcher route `0x69` to
`health_handle_start_measure` (body `0x5ef4`). The mode dispatch is:

```text
0x00005f60  cmp r0, 3     ; mode 0x03 -> HR mode 0x20
0x00005f66  cmp r0, 9     ; mode 0x09 -> FUN_00834862 + HR mode 0x400
0x00005f6a  cmp r0, 0x0b  ; mode 0x0B -> HR mode 0x1000 + step-calibration
0x00005f6e  cmp r0, 0x0d  ; mode 0x0D -> HR mode 1
0x00005f72  cmp r0, 0x0e  ; mode 0x0E -> HR mode 0x20
0x00005f76  cmp r0, 0x0c  ; mode 0x0C -> complex init + data-driven param
0x00005fce  cmp r0, 6     ; mode 0x06 -> HR continuous sub-machine
```

There is **no `cmp r0, 7` branch**. Mode `0x07` (the APK/SDK ECG type) falls
through to the common fallback that calls `health_post_start_measure_event(1)`.
This corroborates PROTOCOL.md's note that H59MA v14 has no dedicated ECG
session path.

## `0x6a` stop handler

Body `0x5de2` sends a response whose opcode is explicitly `0x6a`:

```text
0x00005e56  movs r0, 0x6a
0x00005e5a  strb r0, [sp]                ; frame[0] = 0x6a
0x00005e5e  ldrb r0, [r4, 1]
0x00005e60  strb r0, [sp, 1]             ; frame[1] = mode echo
...
0x00005e62  bl 0x4cc4                    ; checksum
0x00005e66  bl 0x87dc                    ; enqueue
```

## SpO2 / PPG control (`0x2c`)

The Channel-A dispatcher handles opcode `0x2c` at body `0x6dc2`. It accepts
sub-commands 1/2/3:

```text
0x00006dd6  ldrb r0, [r4, 1]             ; sub
0x00006dde  cmp r0, 1                    ; read/enable
0x00006de0  cmp r0, 2                    ; write/disable
0x00006de2  cmp r0, 3                    ; refresh
```

The state-update helper at body `0x6e0c` stores the cadence byte `0x3c`
(60) and starts a timer with interval `0x2000` (~8.2 s) for sub-command 1,
and clears it for sub-command 2:

```text
0x00006e14  movs r4, 0x3c                ; cadence = 60
0x00006e16  movs r0, 1; lsls r0, 0xd     ; interval = 0x2000
0x00006e32  strb r4, [r3, 8]             ; store cadence
0x00006e34  bl 0xd31e                    ; start timer
```

This is **not** a real-time PPG data stream; it is an enable-bit plus a
periodic auto-measure cadence, exactly as PROTOCOL.md §3.10 describes.

## Cross-checks against repo docs

- `firmwares/GHIDRA_DECOMPILATION.md` §8.5 identifies the same `0x69`
  handler and mode table; this radare2 pass independently confirms the
  opcode bytes and timer addresses from the raw binary.
- `PROTOCOL.md` §8.5 lists ECG/PPG notify opcodes as "needs live capture";
  static firmware RE now shows H59MA v14 has no ECG-specific `0x69` mode
  and no real-time PPG stream beyond `0x2c` auto-measure.

## Open questions remaining

- Exact semantic names for modes `0x03, 0x09, 0x0B, 0x0C, 0x0D, 0x0E`:
  they all route through `health_post_start_measure_event` with different
  parameters, but which maps to SpO2 / HRV / stress / etc. still requires
  either live captures or symbol names not present in the stripped binary.
- The payload bytes beyond `[cmd, mode, 0x01, 0x00]` in the live `0x69`
  notify: the timer callback at `0x4e98` sends a minimal status frame;
  the richer value-bearing path is the alternate mode-6 branch at
  `0x52d4`, which puts a sensor reading into `frame[3]`. Correlating that
  byte with HR/BP/SpO2 values needs a live trace.
