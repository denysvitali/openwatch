# OTA Container Runtime Validation Evidence

Firmware: `firmwares/_re/v14/body.bin`.

radare2 setup:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  firmwares/_re/v14/body.bin
```

## Init Metadata Is Nine Bytes

Command:

```sh
pd 90 @ 0x8db6
```

`ota_cmd_init_metadata` accepts exactly nine payload bytes. Byte 0 must be
`0x01` or `0x04`; bytes 1..4 are the expected image size, bytes 5..6 are the
declared CRC16, and bytes 7..8 are the declared additive checksum. It resets
the written-byte and packet-index counters, then enters OTA state 2.

```text
0x00008dbe  0929       cmp r1, 9
0x00008dc6  0178       ldrb r1, [r0]
0x00008dc8  0129       cmp r1, 1
0x00008dcc  0429       cmp r1, 4
0x00008dda  c178       ldrb r1, [r0, 3]
0x00008ddc  8578       ldrb r5, [r0, 2]
0x00008de2  4678       ldrb r6, [r0, 1]
0x00008dec  2c43       orrs r4, r5
0x00008df0  d560       str r5, [r2, 0xc]
0x00008df2  d580       strh r5, [r2, 6]
0x00008df8  9460       str r4, [r2, 8]
0x00008dfe  8479       ldrb r4, [r0, 6]
0x00008e06  5180       strh r1, [r2, 2]
0x00008e08  017a       ldrb r1, [r0, 8]
0x00008e10  9080       strh r0, [r2, 4]
0x00008e14  5070       strb r0, [r2, 1]
```

## Data Packet 1 Checks Only The First Word

Command:

```sh
pd 180 @ 0x8e40
```

Each data packet starts with a u16 little-endian 1-based packet index. The first
data packet takes the special branch because the previously stored packet index
is zero. It copies only the first `0x50` bytes to a stack buffer and compares
the first word with the OTA container magic `0x81bdc3e5`.

```text
0x00008e68  7978       ldrb r1, [r7, 1]
0x00008e6a  3878       ldrb r0, [r7]
0x00008e6e  4018       adds r0, r0, r1
0x00008e72  e888       ldrh r0, [r5, 6]
0x00008e74  421c       adds r2, r0, 1
0x00008e76  8a42       cmp r2, r1
0x00008e9a  0028       cmp r0, 0
0x00008ef0  5022       movs r2, 0x50
0x00008ef2  3946       mov r1, r7
0x00008ef4  08a8       add r0, sp, 0x20
0x00008ef6  10f4a7f2   bl 0xff819448
0x00008efa  6049       ldr r1, [0x0000907c] ; 0x81bdc3e5
0x00008efc  0898       ldr r0, [sp, 0x20]
0x00008efe  8842       cmp r0, r1
```

The magic literal has one direct data xref from this handler:

```text
/x e5c3bd81
0x0000907c hit0_0 e5c3bd81

axt 0x907c
fcn.00008e40 0x8efa [DATA:r--] ldr r1, [0x0000907c]
```

## Runtime Strips `0x50`, Not The Full `0x450` File Header

After the first-word check, the data path stages bytes starting at file offset
`0x50`. The 32-byte `image_digest` at file offset `0x1c4` is therefore copied
as part of the staged image, but this runtime OTA body does not parse or
validate it.

```text
0x00008f5e  2246       mov r2, r4
0x00008f60  503a       subs r2, 0x50
0x00008f62  3946       mov r1, r7
0x00008f66  5031       adds r1, 0x50
0x00008f68  1c98       ldr r0, [sp, 0x70]
0x00008f6a  10f46df2   bl 0xff819448
0x00008f70  f9f7f6ff   bl 0x2f60
0x00008eca  8019       adds r0, r0, r6
0x00008ece  1c99       ldr r1, [sp, 0x70]
0x00008ed0  faf79af8   bl 0x3008
```

The v14 container digest is present in the on-disk file at `0x1c4`, which is
inside the region staged after the `0x50` strip:

```text
px 0x40 @ 0x1c0
0x000001c0  0000 0000 47d3 b81a 3403 4731 132e f839
0x000001d0  435d 7ee7 91ec 57e8 c6d6 48da ff09 4a4d
0x000001e0  0d35 4648 0000 0000 0000 0000 0000 0000
```

Searching the v14 runtime body for that 32-byte digest returns no hits:

```text
/x 47d3b81a34034731132ef839435d7ee791ec57e8c6d648daff094a4d0d354648
```

## Complete Checks Only Staged Length

Command:

```sh
pd 70 @ 0x8f78
```

The check/complete worker requires state 3 and compares `written_bytes` against
`expected_size - 0x50`. It does not read a digest field.

```text
0x00008f84  0329       cmp r1, 3
0x00008f92  8168       ldr r1, [r0, 8]
0x00008f94  c368       ldr r3, [r0, 0xc]
0x00008f96  5039       subs r1, 0x50
0x00008f98  8b42       cmp r3, r1
0x00008fa6  0421       movs r1, 4
0x00008fa8  4170       strb r1, [r0, 1]
0x00008fac  0420       movs r0, 4
0x00008fae  9047       blx r2
```

Conclusion: H59MA v14 `body.bin` validates OTA transport metadata, the first
container word, packet order, packet length, erase/write boundaries, and final
staged length. It stages the digest-containing region but does not compute or
compare the 32-byte `image_digest`. If that digest is enforced, it must happen
in the bootloader/apply path outside this runtime body.
