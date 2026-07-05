# Persistent Config Blob Magic Evidence

Firmware: `firmwares/_re/v14/body.bin`, cross-checked against v13 where noted.

radare2 setup:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  firmwares/_re/v14/body.bin
```

## The "Wrong Signature" String Is Config-Blob Magic

Command:

```sh
/ wrong signature
px 0x80 @ 0x1a330
aaa; axt 0x1a348
```

The string exists in v14 at body `0x1a348` and is referenced by
`cfg_blob_magic_ok` at body `0x1a324` (`0x00840724` absolute).

```text
0x0001a340  2046 10bd e2be 2187 7772 6f6e 6720 7369
0x0001a350  676e 6174 7572 6521 2052 6561 6420 2538
0x0001a360  5820 213d 2052 6571 7572 6965 6420 2538
0x0001a370  580a 0000

axt 0x1a348
fcn.0001a324 0x1a336 [STRN:r--] adr r1, 0x10
```

The same string/check is present in v13 at body `0x1b5c8`, with the same
required magic value.

## Required Magic Is `0x8721bee2`

Command:

```sh
pd 55 @ 0x1a300
```

`cfg_blob_magic_ok` reads a little-endian u32 from the caller-supplied blob
pointer and compares it with `0x8721bee2`. On mismatch, it logs the "wrong
signature" string with the value it read.

```text
0x0001a324  10b5       push {r4, lr}
0x0001a326  0124       movs r4, 1
0x0001a328  fdf73cfc   bl 0x17ba4
0x0001a32c  054b       ldr r3, [0x0001a344] ; 0x8721bee2
0x0001a32e  9842       cmp r0, r3
0x0001a332  0246       mov r2, r0
0x0001a334  2320       movs r0, 0x23
0x0001a336  04a1       adr r1, 0x10        ; "wrong signature! ..."
0x0001a33a  c5f764d9   bl 0xff7df606
0x0001a33e  0024       movs r4, 0
0x0001a340  2046       mov r0, r4
```

The helper at `0x17ba4` is just a little-endian u32 load:

```text
0x00017ba4  8178       ldrb r1, [r0, 2]
0x00017ba6  c278       ldrb r2, [r0, 3]
0x00017ba8  0378       ldrb r3, [r0]
0x00017bb2  1002       lsls r0, r2, 8
0x00017bb4  1843       orrs r0, r3
0x00017bb6  0843       orrs r0, r1
```

## Callers Are Config Lookup Paths

Command:

```sh
aaa; axt 0x1a324
```

v14 has two callers:

```text
fcn.0001a7e0 0x1a7ee [CALL:--x] bl fcn.0001a324
fcn.0001dd5c 0x1dd7e [CALL:--x] bl fcn.0001a324
```

`0x1a7e0` (`0x00840be0` absolute) is the config-item scanner. It validates the
blob header, then starts parsing records after offset `+6`:

```text
0x0001a7ec  0498       ldr r0, [sp, 0x10]
0x0001a7ee  fff799fd   bl 0x1a324
0x0001a7f2  0028       cmp r0, 0
0x0001a7f6  049d       ldr r5, [sp, 0x10]
0x0001a7fa  e979       ldrb r1, [r5, 7]
0x0001a7fc  a879       ldrb r0, [r5, 6]
0x0001a800  4018       adds r0, r0, r1
0x0001a80a  0930       adds r0, 9
0x0001a812  ad1d       adds r5, r5, 6
```

`0x1dd5c` (`0x0084415c` absolute) is the config item `0x33` reader. It passes
absolute base `0x00801400`, asks for item id `0x33`, length `6`, and copies the
six-byte value on success.

```text
0x0001dd62  144c       ldr r4, [0x0001ddb4] ; 0x801400
0x0001dd6e  3320       movs r0, 0x33
0x0001dd72  0880       strh r0, [r1]
0x0001dd74  0620       movs r0, 6
0x0001dd7e  fcf7d1fa   bl 0x1a324
0x0001dd8c  fcf728fd   bl 0x1a7e0
0x0001dd98  0622       movs r2, 6
0x0001dd9a  2118       adds r1, r4, r0
0x0001dda0  fbf752db   bl 0xff819448
```

Conclusion: the log text's "signature" is a legacy name for the persistent
config blob magic `0x8721bee2`. This check is not an OTA image digest,
cryptographic signature, or bootloader-only compare.
