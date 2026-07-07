# H59MA v14 — Ultracode radare2 pass: dispatcher correction, ECG/PPG, BP, FEE7 0x9d

Date: 2026-07-07.  
Target: `firmwares/H59MA_1.00.14_260508.bin`, loaded at `0x00826000` in radare2.

## 1. Channel-A deferred dispatcher — address correction

The dispatcher previously documented at `channel_a_dispatch_queued_frame`
(`0x0082d2dc`) is **not the dispatcher**. At that address radare2 disassembles
nonsense (`ldc2 p1, c2, [lr]` for bytes `9e fd 00 21`) and then falls into a
16-byte stub. The real deferred dispatcher is `fcn.0082d32c` at `0x0082d32c`,
called from `qc_app_task` at `0x00827310`.

Commands:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'pd 20 @ 0x0082d2dc' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'pd 80 @ 0x0082d32c' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'aaa; axt @ 0x0082d32c' firmwares/H59MA_1.00.14_260508.bin
```

Key disassembly at `0x0082d32c`:

```text
0x0082d32c  70b5  push {r4, r5, r6, lr}
0x0082d32e  584d  ldr r5, [0x0082d490]        ; queue state ptr
0x0082d330  1435  adds r5, 0x14
0x0082d332  eee0  b 0x82d512
...
0x0082d348  0129  cmp r1, 1                   ; opcode 0x01
0x0082d350  7cd0  beq 0x82d44c
...
0x0082d44c  2046  mov r0, r4
0x0082d44e  fef7a6fb  bl 0x82bb9e             ; 0x01 handler
```

Consequence: **every v14 Channel-A handler address published in earlier
Ghidra/PROTOCOL.md tables is 0x50 bytes too low**. The correct handler start
addresses are the documented values plus `0x50`.

Examples verified:

| Opcode | Old (wrong) | New (correct) | Note |
|---:|---:|---:|---|
| `0x01` | `0x0082bb4e` | `0x0082bb9e` | setTime |
| `0x06` | `0x0082d298` | `0x0082d2e8` | DND |
| `0x0e` | `0x0082cb28` | `0x0082cb78` | bpReadConfirm |
| `0x15` | `0x0082cf48` | `0x0082cf98` | readHeartRate |
| `0x18` | `0x0082ccb6` | `0x0082cd06` | displayClock |
| `0x72` | `0x00829e92` | `0x00829ee2` | pushMsgUint |
| `0xc7` | `0x00832ebc` | `0x00832f0c` | motor/vibration |
| `0xff` | `0x0082cde8` | `0x0082ce38` | factory reset |

## 2. Vendor/high dispatcher — address correction

The function previously labeled `vendor_high_dispatch_command` at `0x0082c944`
is an **interior OTA-control branch** (`req[1] == 1/2` paths abort OTA state).
The real dispatcher body is `fcn.0082c646` at `0x0082c646`; the guarded GATT
entry point is `0x0082c994`, called from the Channel-A write handler at
`0x0082e906`.

Commands:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'pd 20 @ 0x0082c994' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'aaa; axt @ 0x0082c994' firmwares/H59MA_1.00.14_260508.bin
```

At `0x0082c994`:

```text
0x0082c994  694a  ldr r2, [0x0082cb3c]    ; flag ptr
0x0082c996  1278  ldrb r2, [r2]
0x0082c998  012a  cmp r2, 1
0x0082c99a  02d0  beq 0x82c9a2
0x0082c99c  1029  cmp r1, 0x10            ; length must be 16
0x0082c99e  00d1  bne 0x82c9a2
0x0082c9a0  51e6  b 0x82c646              ; dispatch
0x0082c9a2  7047  bx lr                   ; ignore
```

The low-range switch table is at `0x0082c66c`; the high-range switch table is at
`0x0082c730`.

## 3. FEE7 `0x9d` emits a vendor NAK, not silence

In the high-range switch table at `0x0082c730`, the slot for `0x9d` falls
through to the default vendor-NAK sender (`0x0082c79e`). The response shape is
`[0x9d | 0x80, 0xee]` — request opcode with the error flag set, followed by the
vendor-NAK marker `0xee`.

This contradicts the earlier "HighNoResponse" classification that grouped
`0x9d` with `0x97`/`0x99`/`0x9f`.

## 4. ECG/PPG notify opcodes — negative result for H59MA v14

Radare2 string searches for `ecg`, `ppg`, `ECG`, `PPG` return **no hits** in the
v14 body. The VC30F / `lib_BIODetect` / `spo2_VC30F` string block exists but
has **no code cross-references** in the static image. The FEE7 high-range
handlers `0x97-0xA0` are all session/status/model handlers. Channel-A `0x15` and
`0x1e` paths handle heart-rate history and live HR only.

Commands:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'izz~ecg' firmwares/H59MA_1.00.14_260508.bin
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'izz~ppg' firmwares/H59MA_1.00.14_260508.bin
```

Conclusion: H59MA v14 **does not contain dedicated ECG/PPG notify opcodes** in
its static image. Any ECG/PPG support would have to be on a different firmware
revision or reached through an uncaptured dynamic path.

## 5. BP-history `0x0d` compact-byte encoding

The `0x0d` BP-history stream is a compact projection of 24 hourly 4-byte
persistent slots. Only **byte 0** of each valid slot is copied into the payload.
Validity is clamped to `[0x28, 0xdc]` (40–220) before inclusion in the presence
bitmap.

The stored byte appears to be produced by a measurement routine that averages
sensor reads, divides by 5, and adds `0x46` (70). The Ghidra-decompiled division
return register is ambiguous, so the exact clinical mapping still needs live
cuff correlation.

A separate two-output routine (`FUN_008340e2`) computes systolic/diastolic-like
clamped values using constants `0x82/0x5a/0x50/0x3c/0x3b/0x19/0x32`; its
relationship to the single stored byte is unproven.

## 6. Helper functions identified

23 previously auto-named functions were located and given descriptive names.
They span health/sensor event logging, I2C sensor bus, OS timers,
motor/vibration, activity step events, and BLE GAP name/advertising
construction. The full list is in the proposed `firmwares/GHIDRA_DECOMPILATION.md`
§11 update.

## Impact on docs

- `firmwares/PROTOCOL.md` — update dispatcher addresses, handler addresses
  (+0x50), ECG/PPG classification, BP compact-byte note, FEE7 `0x9d` row.
- `firmwares/GHIDRA_DECOMPILATION.md` — update §3 and §8.1 dispatcher
  addresses, switch-table bases, `0x9d` description; add §11 helper-function
  symbol pass.
- `firmwares/FIRMWARE_ANALYSIS.md` — point to `0x0082d32c` as the real
  deferred dispatcher.

## Bottom line

This pass corrects a systematic 0x50 address offset in the published Channel-A
handler tables, relocates the vendor/high dispatcher, resolves ECG/PPG as
absent on H59MA v14, clarifies BP-history wire encoding, and fixes the FEE7
`0x9d` response classification.
