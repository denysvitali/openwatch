# FEE7 GATT Handler radare2 Evidence

Date: 2026-07-05

Scope: H59MA v14 OTA body at `firmwares/_re/v14/body.bin`. Offsets are body
offsets unless an absolute address is shown.

This pass corrects an earlier Ghidra naming mistake: the handlers at
`0x0082e850`, `0x0082e87a`, and `0x0082e8ce` belong to the Channel-A
`6e40fff0` service table, not to the vendor `0xFEE7` table.

## Attribute Table Split

Command:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'px 0x140 @ 0x1f2a0' firmwares/_re/v14/body.bin
```

Key bytes:

```text
0x1f2a8  1100 0000 51e8 8200 7be8 8200 cfe8 8200
0x1f2b8  0208 0028 e7fe 0000 ...
...
0x1f3b0  1100 0000 a3e9 8200 4dea 8200 bbea 8200
```

Interpretation:

| Service | Attribute table | Callback block | Read | Write | CCCD |
|---|---:|---:|---:|---:|---:|
| Channel A `6e40fff0` | `0x1f204..0x1f2a8` | `0x1f2aa` | `0x0082e851` | `0x0082e87b` | `0x0082e8cf` |
| Vendor `0xFEE7` | `0x1f2b8..0x1f3ac` | `0x1f3b2` | `0x0082e9a3` | `0x0082ea4d` | `0x0082eabb` |

The words immediately before the `0xFEE7` service declaration are the Channel-A
callback block. They are not FEE7 characteristic handlers.

## Registration Calls

Command:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'pd 40 @ 0x8064; pd 60 @ 0x84ec; pd 50 @ 0x870a' \
  firmwares/_re/v14/body.bin
```

Key instructions:

```text
0x806c  ldr r0, [0x812c] ; 0x0082dd35
0x806e  bl 0x84ec
...
0x8088  ldr r0, [0x812c] ; 0x0082dd35
0x808a  bl 0x870a

0x84ee  ldr r1, [0x8538] ; 0x00845684
0x8500  movs r2, 0xa8
0x8502  subs r1, 0x80    ; table base 0x00845604 == body 0x1f204

0x870c  ldr r1, [0x876c] ; 0x008457b8
0x871e  movs r2, 0xfc
0x8720  subs r1, 0x80    ; table base 0x008456b8 == body 0x1f2b8
```

`ble_services_init` registers Channel A first (`0x84ec`, table `0x1f204`) and
FEE7 last (`0x870a`, table `0x1f2b8`). Both receive the common service callback
at `0x0082dd35`.

## Write Handler Behavior

Commands:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'pd 80 @ 0x847a; pd 120 @ 0x864c; pd 170 @ 0x7934' \
  firmwares/_re/v14/body.bin
```

Channel-A write callback:

```text
0x847a  push {r3, r4, r5, lr}
...
0x8488  cmp r2, 2
0x848a  beq 0x84b6
...
0x84b6  bl 0x6544
```

The Channel-A write path is the one that calls the 16-byte opcode dispatcher at
`0x6544` for GATT event `2` with length `0x10`.

FEE7 write callback:

```text
0x864c  push {r4, r5, r6, r7, lr}
...
0x8658  cmp r2, 7
0x865a  beq 0x8674
...
0x868c  ldr r2, [r0, 8]
0x8696  blx r2
```

The true FEE7 write callback only packages a Realtek service write event and
calls the common callback stored during registration. It has no direct branch
to `0x6544`.

Common callback:

```text
0x7934  push {r3, r4, r5, lr}
...
0x7950  cmp r2, 2
0x7954  cmp r2, 3
...
0x79e0  ldrb r2, [r1, 4]
0x79e6  ldrh r2, [r1, 6]
0x79ec  ldr r1, [0x7a70]
0x79f2  bl 0xff7df6a8
```

For the write-event shape emitted by the FEE7 callback, the common callback
logs the subtype and length. It does not parse a 16-byte command frame.

## Conclusion

Static firmware routing proves that the `0x6544` vendor/high opcode dispatcher
is reached from the Channel-A GATT write callback, while the published
`0xFEE7` service has its own Realtek event handlers. Treat `0xFEE7` writes as a
live-capture/probe surface only until captures prove a command payload contract.
