# Channel-B Dispatcher radare2 Evidence

Date: 2026-07-05

Scope: H59MA v13/v14 OTA bodies at `firmwares/_re/v13/body.bin` and
`firmwares/_re/v14/body.bin`. Offsets are body offsets.

Tooling:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
```

## First-Stage Dispatcher

Commands:

```sh
r2 ... -c 'pd 120 @ 0x8ae6' firmwares/_re/v14/body.bin
r2 ... -c 'pd 120 @ 0x8b2e' firmwares/_re/v13/body.bin
```

Result:

- v14 `0x8ae6..0x8b4e` and v13 `0x8b2e..0x8b96` are the same decision tree.
- The dispatcher computes CRC-16/MODBUS over `payload` (`bl 0x8d14` v14,
  `bl 0x8d5c` v13), compares it with the stored CRC field, and calls the
  compact NAK sender with status `2` on mismatch.
- Pre-store `ota_dfu_state_machine(1, 0)` callback, then async-store route:
  `0x01`, `0x02`, `0x21`, `0x31`, `0x35`, `0x36`, `0x61`.
- Bypass/no async-store route: `0x10`, `0x46`; both branch to the cleanup /
  state-reset helper at v14 `0x8abe`.
- Every other valid-CRC command calls the async store (`0x90fa` v14,
  `0x9142` v13) directly with `(cmd, payload_ptr, length)`.

Key v14 compare sequence:

```text
0x00008b08  cmp r0, 0x31
0x00008b0e  cmp r0, 1
0x00008b12  cmp r0, 2
0x00008b16  cmp r0, 0x10
0x00008b1a  cmp r0, 0x21
0x00008b20  cmp r0, 0x35
0x00008b24  cmp r0, 0x36
0x00008b28  cmp r0, 0x46
0x00008b2c  cmp r0, 0x61
```

## Async Worker

Commands:

```sh
r2 ... -c 'pd 220 @ 0x980c' firmwares/_re/v14/body.bin
r2 ... -c 'pd 220 @ 0x9854' firmwares/_re/v13/body.bin
```

Result:

- v14 `0x980c..0x9932` and v13 `0x9854..0x997a` drain the async command
  state (`cmd` at `+1`, payload pointer at `+4`, length at `+0xc`).
- Low commands `0x00..0x10` enter a compiler-generated Thumb switch helper.
- Commands `0x11..0x5a` use a plain compare cascade.
- On exit, both versions clear the async command byte (`strb 0, [state+1]`).

Confirmed compare-cascade commands:

| Command | Routing |
|---:|---|
| `0x11` | sleep summary |
| `0x12` | detailed sleep |
| `0x13` | no-op / skipped |
| `0x21..0x24` | NAK status `2` |
| `0x27` | sleep records |
| `0x29`, `0x3b` | no-op / skipped |
| `0x2a` | activity summary |
| `0x2c` | alarm read/write |
| `0x41`, `0x43` | file table / file operation handler |
| `0x46` | unreachable async file-handler branch; normal on-wire path bypasses async storage |
| `0x47`, `0x4b` | no-op placeholder handlers |
| `0x5a` | device-info/config TLV handler |
| other | NAK status `0` |

Note: the async worker has a `0x46` file-command branch, but the first-stage
complete-frame dispatcher branches parsed `0x46` frames around the async-store
call. If another firmware path seeds the async state with `cmd = 0x46`, the
local handler at `0xadb8` still returns immediately because it only handles
`0x41` and `0x43`.

The APK-era generic FileHandle ids are likewise not usable on H59MA v14:
`0x30`, `0x32`, `0x33`, and `0x39` are neither first-stage special cases nor
async compare-cascade entries, so they use the `other` NAK status `0` path.
`0x31` is first-stage special only for the `ota_dfu_state_machine(1, 0)`
pre-store callback; after it is queued, the async worker has no `0x31` branch
and also returns NAK status `0`.

The APK-era high media ids `0x80`, `0x81`, and `0x82` are above every
implemented async compare. v14 checks `0x4b` at `0x9882`, `0x5a` at `0x9886`,
then falls through to `0x988a movs r1, 0`; v13 does the same at
`0x98ca..0x98d2`.

### No-response placeholders

`0x13`, `0x29`, and `0x3b` compare equal in the cascade and branch directly to
async-state cleanup (`strb 0, [state+1]`) without a helper call and without
`channel_b_send_nak`.

`0x47` and `0x4b` pass `payload[0]` to placeholder helpers, then also branch to
cleanup:

```text
v14:
0x00009872  cmp r0, 0x47
0x00009874  beq 0x9896
0x00009896  ldrb r0, [r4]
0x00009898  bl 0xe3fa

0x00009882  cmp r0, 0x4b
0x00009884  beq 0x98c4
0x000098c4  ldrb r0, [r4]
0x000098c6  bl 0xa060

0x0000e3fa  bx lr
0x0000a060  bx lr
```

v13 has the same shape at `0x98ba`/`0x98de` -> `0xe3ea` and
`0x98ca`/`0x990c` -> `0xa0a8`; both callees are also single `bx lr`
instructions.

### Sleep `0x27` emits response `0x3e`

Direct host requests for lunch/nap sleep still use command `0x27`. The
`0x3e` value is a response opcode emitted only by the `0x27` handler when the
second payload byte is `1`; direct host `0x3e` frames have no async compare
entry and default to NAK status `0`.

```text
v14:
0x000096fc  cmp  r7, 1        ; r7 = payload[1]
0x000096fe  bne  0x9784       ; skip nap pass unless recordType == 1
...
0x0000977a  movs r0, 0x3e
0x0000977c  bl   0x88e0       ; emit nap/lunch response
...
0x000097fe  movs r0, 0x27
0x00009800  bl   0x88e0       ; always emit night response

v13:
0x00009744  cmp  r7, 1
0x00009746  bne  0x97cc
0x000097c2  movs r0, 0x3e
0x000097c4  bl   0x8928
0x00009846  movs r0, 0x27
0x00009848  bl   0x8928
```

### APK LargeData ids are not a generic map

The APK `respMap[action]` inventory does not correspond to a generic H59MA
Channel-B dispatcher. The only APK action ids with implemented H59MA handlers
in the async cascade are `0x27` sleep records, `0x2a` activity/sport summary,
and `0x2c` alarm read/write. `0x29` and `0x47` are recognized no-response
placeholders. The APK ids `0x20`, `0x28`, `0x2d`, `0x2e`, `0x2f`, `0x3a`,
`0x3e` as a direct request, `0x48`, `0x49`, `0x4a`, `0x4c`, `0x5f`, and
`0x75` all use the default NAK status `0` path.

### Explicit NAK-code-2 rejects

`0x21`, `0x22`, `0x23`, and `0x24` are recognized compare-cascade entries, not
the default unknown-command path. Each branch lands on the shared
`movs r1, 2; bl channel_b_send_nak` block while `r0` still holds the original
command. The unknown-command path sets `r1 = 0` before the same sender call.

```text
v14:
0x0000981c  cmp  r0, 0x24
0x0000981e  beq  0x98e4
0x00009838  cmp  r0, 0x21
0x0000983a  beq  0x98e4
0x00009848  cmp  r0, 0x22
0x0000984a  beq  0x98e4
0x0000984c  cmp  r0, 0x23
0x0000984e  bne  0x988a
0x00009850  b    0x98e4
0x0000988a  movs r1, 0
0x0000988c  b    0x98e6
0x000098e4  movs r1, 2
0x000098e6  bl   0x8a00

v13:
0x00009864  cmp  r0, 0x24
0x00009866  beq  0x992c
0x00009880  cmp  r0, 0x21
0x00009882  beq  0x992c
0x00009890  cmp  r0, 0x22
0x00009892  beq  0x992c
0x00009894  cmp  r0, 0x23
0x00009896  bne  0x98d2
0x00009898  b    0x992c
0x000098d2  movs r1, 0
0x000098d4  b    0x992e
0x0000992c  movs r1, 2
0x0000992e  bl   0x8a48
```

## Low-Command Switch Shape

Commands:

```sh
r2 ... -c 'px 0x0c @ 0x982e' firmwares/_re/v14/body.bin
r2 ... -c 'px 0x0c @ 0x9876' firmwares/_re/v13/body.bin
```

Both builds dump the same bytes:

```text
08 2e 5f 63 69 6d 71 2e 75 2e
```

The switch helper at `0x1a1fc` reads the byte at `lr - 1` as the maximum
explicit index, then clamps any command greater than or equal to that value to
the last branch-entry byte:

```text
0x0001a200  subs r4, r4, 1
0x0001a202  ldrb r5, [r4]      ; max explicit index = 0x08
0x0001a206  cmp  r3, r5
0x0001a208  bhs  0x1a20c       ; keep r5 (default index) when cmd >= 8
0x0001a20a  mov  r5, r3        ; else use cmd as index
0x0001a20c  ldrb r3, [r4, r5]  ; branch-entry byte
```

Interpretation:

| Command | Branch byte | Meaning |
|---:|---:|---|
| `0x00` | `0x2e` | default NAK status `0` |
| `0x01` | `0x5f` | OTA start ack |
| `0x02` | `0x63` | OTA init metadata |
| `0x03` | `0x69` | OTA data packet |
| `0x04` | `0x6d` | OTA check complete |
| `0x05` | `0x71` | OTA end/reboot |
| `0x06` | `0x2e` | default NAK status `0` |
| `0x07` | `0x75` | OTA sub-ack |
| `0x08..0x10` | `0x2e` | clamped default NAK status `0` |

Earlier notes over-read the bytes after the 9 branch entries (`21 28 ...`) as
additional switch entries. They are the next compare-cascade instruction
(`cmp r0, 0x21`), not part of the table.
