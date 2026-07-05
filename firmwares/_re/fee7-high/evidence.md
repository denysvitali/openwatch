# FEE7 High-Opcode radare2 Evidence

Scope: H59MA v14 OTA body at `firmwares/_re/v14/body.bin`. Offsets are body
offsets in the extracted image.

Common radare2 invocation:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c '<cmd>' firmwares/_re/v14/body.bin
```

## Dispatcher Range

Command:

```sh
r2 ... -c 'px 0x30 @ 0x62dc; pd 80 @ 0x62d8' firmwares/_re/v14/body.bin
```

Important bytes:

```text
0x000062dc  13f0 8eff 0acb cfd3 d7db df37 e3eb e737
0x000062ec  0023 0122 fe49 c728 b5d0 14dc c228 2ad0
0x000062fc  08dc b028 27d0 bf28 71d0 c028 70d0 c128
```

The dispatcher subtracts `0x97` and calls the jump-table helper at `0x1a1fc`.
The table count byte is `0x0a`, followed by eleven table bytes:

```text
cb cf d3 d7 db df 37 e3 eb e7 37
```

The compare cascade after the table verifies the high opcodes outside the
`0x97..0xa0` range:

```text
0x00006302  bf28       cmp r0, 0xbf
0x00006304  71d0       beq 0x63ea
0x00006306  c028       cmp r0, 0xc0
0x00006308  70d0       beq 0x63ec
0x0000630a  c128       cmp r0, 0xc1
0x0000630e  dee0       b 0x64ce
0x00006310  c328       cmp r0, 0xc3
0x00006312  6cd0       beq 0x63ee
0x00006346  fe28       cmp r0, 0xfe
0x00006348  09d0       beq 0x635e
```

The resolved target block at `0x6476` shows the compact handlers for
`0x97..0xa0`, then raw memory and health/OTA handlers:

```text
0x00006476  2046       mov r0, r4
0x00006478  fbf794f9   bl 0x17a4
...
0x000064be  2046       mov r0, r4
0x000064c0  fff7e8f8   bl 0x5694
0x000064c6  2046       mov r0, r4
0x000064c8  fff720f9   bl 0x570c
0x000064ce  8848       ldr r0, [0x000066f0]
0x000064da  fff72df8   bl 0x5538
0x000064e0  a078       ldrb r0, [r4, 2]
```

## Raw Memory Commands

Command:

```sh
r2 ... -c 'pd 70 @ 0x5694; pd 70 @ 0x570c' firmwares/_re/v14/body.bin
```

`0xbf` builds a big-endian address from `req[1..4]`, clamps `req[5]` to 8
bytes, copies from `req+6`, then sends a self-marker ACK:

```text
0x00005698  e178       ldrb r1, [r4, 3]
0x0000569a  0079       ldrb r0, [r0, 4]
0x000056a0  a178       ldrb r1, [r4, 2]
0x000056a2  6278       ldrb r2, [r4, 1]
0x000056aa  6279       ldrb r2, [r4, 5]
0x000056ae  082a       cmp r2, 8
0x00005702  2078       ldrb r0, [r4]
0x00005706  fff73eff   bl 0x5586
```

`0xc0` builds a big-endian address from `req[1..4]` and a big-endian length
from `req[5..8]`; zero length defaults to `0x10`, and non-zero lengths clamp
to `0x200` before entering the shared streamer at `0x5538`:

```text
0x0000570e  c278       ldrb r2, [r0, 3]
0x00005710  0179       ldrb r1, [r0, 4]
0x00005716  8278       ldrb r2, [r0, 2]
0x00005718  4378       ldrb r3, [r0, 1]
0x00005722  c379       ldrb r3, [r0, 7]
0x00005724  027a       ldrb r2, [r0, 8]
0x0000572a  8379       ldrb r3, [r0, 6]
0x0000572c  4479       ldrb r4, [r0, 5]
0x00005736  08d0       beq 0x574a
0x0000573c  9a42       cmp r2, r3
0x00005748  f6e6       b 0x5538
0x0000574a  1022       movs r2, 0x10
```

## Health Poll and OTA Control

Command:

```sh
r2 ... -c 'pd 55 @ 0x64ce; pd 60 @ 0x64e0' firmwares/_re/v14/body.bin
```

`0xc1` runs the one-shot helper and streams one byte from `0x209f32`:

```text
0x000064ce  8848       ldr r0, [0x000066f0] ; 0x209f32
0x000064d0  06f093ff   bl 0xd3fa
0x000064d4  2078       ldrb r0, [r4]
0x000064d6  0122       movs r2, 1
0x000064d8  8549       ldr r1, [0x000066f0] ; 0x209f32
0x000064da  fff72df8   bl 0x5538
```

`0xc3` reads absolute request bytes `req[2]` then `req[1]`: `req[2] == 1`
calls the BLE/service reset helper, `req[1] == 1` calls
`ota_dfu_state_machine(4, 0)`, and `req[1] == 2` calls
`ota_dfu_state_machine(0, 0)`:

```text
0x000064e0  a078       ldrb r0, [r4, 2]
0x000064e2  0128       cmp r0, 1
0x000064e6  01f07afb   bl 0x7bde
0x000064ea  6078       ldrb r0, [r4, 1]
0x000064ec  0128       cmp r0, 1
0x000064f0  0228       cmp r0, 2
0x000064f4  0021       movs r1, 0
0x000064f6  0846       mov r0, r1
0x000064f8  03f0abfa   bl 0x9a52
0x00006500  0420       movs r0, 4
```

## `0xfe` Synthetic Sleep-History Request

Command:

```sh
r2 ... -c 'pd 35 @ 0x635e; pd 70 @ 0x1de14' firmwares/_re/v14/body.bin
```

The dispatcher loads `req[2]` as the high byte and `req[1]` as the low byte,
calls `0x1de14`, then returns directly to the dispatcher epilogue. There is no
call to the shared response streamer or self-marker ACK helper on this path:

```text
0x0000635e  a078       ldrb r0, [r4, 2]
0x00006360  6178       ldrb r1, [r4, 1]
0x00006362  0002       lsls r0, r0, 8
0x00006364  0843       orrs r0, r1
0x00006366  17f055fd   bl 0x1de14
0x0000636a  f2e7       b 0x6352
```

At `0x1de14`, the callee clamps the duration to `0xe1 << 2 == 900` minutes,
stores the current timestamp/state into the sleep-history work buffer at
`0x20cd48`, and continues building a synthetic sleep record:

```text
0x0001de18  e120       movs r0, 0xe1
0x0001de1a  8000       lsls r0, r0, 2
0x0001de1c  8542       cmp r5, r0
0x0001de20  0546       mov r5, r0
0x0001de2a  3e4c       ldr r4, [0x0001df24] ; 0x20cd48
0x0001de2c  2060       str r0, [r4]
0x0001de2e  e580       strh r5, [r4, 6]
0x0001de30  0120       movs r0, 1
0x0001de32  6071       strb r0, [r4, 5]
0x0001de34  0220       movs r0, 2
0x0001de36  2071       strb r0, [r4, 4]
```

Conclusion: `0xfe` is not a vibration/motor command. It is a fire-and-forget
synthetic sleep-history generator with a u16LE duration argument.
