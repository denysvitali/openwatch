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
