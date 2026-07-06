# BP History `0x0e` / `0x0d` Evidence

Firmware: `firmwares/_re/v14/body.bin`.

radare2 setup:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  firmwares/_re/v14/body.bin
```

## `0x0e` Calls The BP Builder

Command:

```sh
pd 30 @ 0x5ca4
```

`FUN_0082c0a4` allocates two stack buffers, calls `0xde96`, then always sends a
14-byte `0x0d` header unless the builder returned `0xff`. A nonzero builder
return is sent as a second fragmented body.

```text
0x00005ca8  6946       mov r1, sp
0x00005caa  0da8       add r0, sp, 0x34
0x00005cac  08f0f3f8   bl 0xde96
0x00005cb6  0e22       movs r2, 0xe
0x00005cb8  0da9       add r1, sp, 0x34
0x00005cba  0d20       movs r0, 0xd
0x00005cbc  fff73cfc   bl 0x5538
0x00005cc4  2246       mov r2, r4
0x00005cc6  6946       mov r1, sp
0x00005cc8  0d20       movs r0, 0xd
0x00005cca  fff735fc   bl 0x5538
```

`0x5538` is the shared 14-byte payload streamer: it copies up to 14 bytes from
the supplied buffer into `frame[1..14]`, computes the additive checksum, queues
the frame, and repeats until the requested length is exhausted.

```text
0x0000554c  0e2c       cmp r4, 0xe
0x00005558  6946       mov r1, sp
0x0000555a  0e70       strb r6, [r1]
0x00005564  13f470f7   bl 0xff819448
0x0000556c  fff7aafb   bl 0x4cc4
0x00005576  03f031f9   bl 0x87dc
```

## Header Layout And Interval

Command:

```sh
pd 180 @ 0xde96
```

The builder writes a tagged header at the first pointer argument:

```text
0x0000dede  0023       movs r3, 0
0x0000dee0  2b70       strb r3, [r5]      ; header[0] = 0x00
0x0000dee4  5870       strb r0, [r3, 1]   ; yy
0x0000dee8  8170       strb r1, [r0, 2]   ; mm
0x0000deec  c270       strb r2, [r0, 3]   ; dd
0x0000def2  4278       ldrb r2, [r0, 1]
0x0000def4  0a71       strb r2, [r1, 4]   ; interval minutes
```

The default interval byte is initialized to `0x3c` (60 minutes), not a 15-minute
multiplier:

```text
0x0000e098  0a4a       ldr r2, [0x0000e0c4] ; 0x564
0x0000e09a  8a84       strh r2, [r1, 0x24]
0x0000e09c  3c21       movs r1, 0x3c
0x0000e09e  4170       strb r1, [r0, 1]
```

The builder divides the interval by 30, then divides 48 half-hour positions by
that ratio. With the default `0x3c` interval, this scans 24 hourly slots.

```text
0x0000defa  4078       ldrb r0, [r0, 1]
0x0000defc  1e21       movs r1, 0x1e
0x0000defe  09f05cfe   bl 0x17bba
0x0000df04  3022       movs r2, 0x30
0x0000df06  0146       mov r1, r0
0x0000df0c  1046       mov r0, r2
0x0000df0e  09f054fe   bl 0x17bba
0x0000df12  0290       str r0, [sp, 8]
```

## Body Layout

For each valid BP slot, the builder inserts a body tag byte `0x01` whenever the
current body offset is divisible by 14. It then appends exactly one BP byte.
This is why every emitted body frame starts with `payload[0] == 0x01` and has
up to 13 compact values after the tag.

```text
0x0000df66  0e21       movs r1, 0xe
0x0000df68  2046       mov r0, r4
0x0000df6a  09f026fe   bl 0x17bba        ; r1 = body_len % 14
0x0000df6e  0029       cmp r1, 0
0x0000df72  0699       ldr r1, [sp, 0x18]
0x0000df74  0120       movs r0, 1
0x0000df76  0855       strb r0, [r1, r4] ; body[body_len++] = 0x01
0x0000df7c  0198       ldr r0, [sp, 4]
0x0000df7e  0179       ldrb r1, [r0, 4]  ; first byte of 4-byte BP slot
0x0000df80  0698       ldr r0, [sp, 0x18]
0x0000df84  0155       strb r1, [r0, r4] ; body[body_len++] = value
```

The persistent descriptor remains 24 hourly 4-byte BP slots at record offset
`+4`, but this `0x0d` history stream only emits the first byte from each valid
slot. The remaining three bytes are not available to the host through this
opcode.

## FEE7 `0x0d` Uses The Same Compact Sender

The FEE7 low-range dispatcher also has a `0x0d` BP-history entry, but it does
not expose a fuller 4-byte slot. Its inline switch helper at `0x1a1fc` reads
the count byte at `lr - 1` and then selects `tableBase + 2 * table[opcode]`.
For the FEE7 low switch call at `0x6218`, the count byte is `0x27` at
`0x621c`, the table base is `0x621d`, and case `0x0d` has byte `0xef`:

```text
0x0000621c  27 99 23 b6 cb cf 99 23 99 23 99 c0 99 e3 ef ...
                                     case 0x0d ---------^^

target = 0x621d + 2 * 0xef = 0x63fb  (Thumb bit set -> body 0x63fa)
```

The target prepares the recent-day BP cursor and then calls the same `0x5ca4`
sender used by Channel-A `0x0e`:

```text
0x000063fa  bl 0xde52   ; prepare recent BP days
0x000063fe  bl 0x5ca4   ; build/send compact 0x0d chunks
```

The relevant radare2 xrefs in v14 are:

```text
axt 0x5ca4
0x00005cd8  bl 0x5ca4   ; Channel-A wrapper after 0xde52
0x000063fe  bl 0x5ca4   ; FEE7 0x0d branch
0x00006734  bl 0x5ca4   ; sub==0 wrapper after 0xe010

axt 0xde96
0x00005cac  bl 0xde96   ; only the compact sender calls the BP builder
```

The BP descriptor pointer `0x00845ae4` appears as the literal at `0xe0b0`,
which is loaded by `0xde52`/`0xde96`. A byte search for the little-endian word
(`e4 5a 84 00`) found no other literal. Static firmware RE therefore found no
alternate host-visible path that emits the remaining three bytes from each
4-byte BP slot; the FEE7 path converges on the same compact `0x0d` stream.

## `0x0c` BP Setting Interval

Command:

```sh
pd 75 @ 0x5cde
```

The shared FEE7/Channel-A wrapper branches on the first payload byte. `sub=1`
calls the read builder, stamps `payload[0]=1`, and sends seven bytes. `sub=2`
calls the write validator and passes its return value to the ACK helper; a
nonzero return therefore becomes an `opcode | 0x80` error ACK.

```text
0x00005ce4  0178       ldrb r1, [r0]
0x00005ce6  0129       cmp r1, 1
0x00005cea  0229       cmp r1, 2
0x00005cee  08f08ff8   bl 0xde10
0x00005cf2  0146       mov r1, r0
0x00005cf4  2078       ldrb r0, [r4]
0x00005cf6  fff746fc   bl 0x5586
0x00005cfe  08f069f8   bl 0xddd4
0x00005d02  0120       movs r0, 1
0x00005d06  0870       strb r0, [r1]
0x00005d0a  0722       movs r2, 7
0x00005d0c  fff714fc   bl 0x5538
```

Command:

```sh
pd 70 @ 0xddd4
```

The read builder copies the stored enable byte and interval byte, then divides
the stored start/end minute counts by 60 to return hour/minute pairs.

```text
0x0000dddc  0178       ldrb r1, [r0]
0x0000ddde  6170       strb r1, [r4, 1]
0x0000dde0  4078       ldrb r0, [r0, 1]
0x0000dde2  a071       strb r0, [r4, 6]
0x0000dde6  688c       ldrh r0, [r5, 0x22]
0x0000dde8  3c21       movs r1, 0x3c
0x0000ddee  a070       strb r0, [r4, 2]
0x0000ddf8  e170       strb r1, [r4, 3]
0x0000de02  2071       strb r0, [r4, 4]
0x0000de0c  6171       strb r1, [r4, 5]
```

Command:

```sh
pd 58 @ 0xde10
```

The write path treats payload byte 6 as minutes. It rejects zero and values
with a nonzero remainder modulo 30, then stores enable, interval, and
`hour * 60 + minute` start/end windows.

```text
0x0000de14  8079       ldrb r0, [r0, 6]
0x0000de16  0028       cmp r0, 0
0x0000de1a  1e21       movs r1, 0x1e
0x0000de1c  09f0cdfe   bl 0x17bba
0x0000de20  0029       cmp r1, 0
0x0000de24  0120       movs r0, 1
0x0000de2c  0170       strb r1, [r0]
0x0000de30  4170       strb r1, [r0, 1]
0x0000de36  4843       muls r0, r1, r0
0x0000de42  4184       strh r1, [r0, 0x22]
0x0000de46  5143       muls r1, r2, r1
0x0000de4c  8184       strh r1, [r0, 0x24]
```

Command:

```sh
pd 50 @ 0xe078
```

Init defaults confirm the interval is `0x3c` minutes: enable `1`, start `0`,
end `0x0564` minutes (`23:00`), interval `0x3c`.

```text
0x0000e08c  0121       movs r1, 1
0x0000e08e  0170       strb r1, [r0]
0x0000e096  4a84       strh r2, [r1, 0x22]
0x0000e098  0a4a       ldr r2, [0x0000e0c4] ; 0x564
0x0000e09a  8a84       strh r2, [r1, 0x24]
0x0000e09c  3c21       movs r1, 0x3c
0x0000e09e  4170       strb r1, [r0, 1]
```

## Presence Bitmap And Empty Sentinel

The builder ORs a 48-bit presence bitmap as valid values are appended, then
writes the six little-endian bitmap bytes into `header[5..10]` and clears
`header[11..13]`.

```text
0x0000df8a  0120       movs r0, 1
0x0000df8c  0021       movs r1, 0
0x0000df8e  09f000fc   bl 0x17792        ; 1 << slot_index
0x0000df92  0643       orrs r6, r0
0x0000df94  0f43       orrs r7, r1
...
0x0000dfaa  0099       ldr r1, [sp]
0x0000dfb0  4654       strb r6, [r0, r1]
...
0x0000dfea  0818       adds r0, r1, r0
0x0000dfec  0321       movs r1, 3
0x0000dfee  0bf491f2   bl 0xff819514
```

If no valid values are found, it sends a tagged empty/end header by clearing the
14-byte header and writing `header[0] = 0xff`.

```text
0x0000dff8  0e21       movs r1, 0xe
0x0000dffa  0598       ldr r0, [sp, 0x14]
0x0000dffc  0bf48af2   bl 0xff819514
0x0000e002  ff20       movs r0, 0xff
0x0000e004  0870       strb r0, [r1]
```
