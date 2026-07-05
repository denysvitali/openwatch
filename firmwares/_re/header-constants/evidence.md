# Firmware Header Constant Evidence

Images:

- `firmwares/H59MA_1.00.13_251230.bin`
- `firmwares/H59MA_1.00.14_260508.bin`
- carved bodies under `firmwares/_re/v13/body.bin` and
  `firmwares/_re/v14/body.bin`

## Header Constant Slots

Command:

```sh
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c 'px 0x190 @ 0x50' firmwares/H59MA_1.00.14_260508.bin
```

v14 header constants:

```text
0x00000050  0c00 8109 9327 0000 fc15 0200 f94c 6b7e
...
0x000000b0  4110 0000 9ea3 0112 7364 6b23 2323 2323
...
0x000001c0  0000 0000 47d3 b81a 3403 4731 132e f839
```

Relevant decoded fields:

```text
container[0x5c]  = 0x7e6b4cf9
container[0xb4]  = 0x1201a39e
container[0x228] = 0x0e85d101
```

## Body Literal Searches

Command:

```sh
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c '/x f94c6b7e; /x 9ea30112; /x 01d1850e' firmwares/_re/v14/body.bin
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c '/x f94c6b7e; /x 9ea30112; /x 01d1850e' firmwares/_re/v13/body.bin
```

Body search results:

```text
v14: no hits for 0x7e6b4cf9 (`f94c6b7e`)
v14: no hits for 0x1201a39e (`9ea30112`)
v14: body 0x1f814 hit for 0x0e85d101 (`01d1850e`)

v13: no hits for 0x7e6b4cf9 (`f94c6b7e`)
v13: no hits for 0x1201a39e (`9ea30112`)
v13: body 0x21460 hit for 0x0e85d101 (`01d1850e`)
```

Full-container searches confirm `0x0e85d101` appears twice per image: the header
field at `0x228`, and the runtime-tail marker at the `flash_app_end` body
boundary (`body_offset + 0x450`).

```text
v14 /x 01d1850e
0x00000228 hit2_0 01d1850e
0x0001fc64 hit2_1 01d1850e   # body 0x1f814 + 0x450

v13 /x 01d1850e
0x00000228 hit2_0 01d1850e
0x000218b0 hit2_1 01d1850e   # body 0x21460 + 0x450
```

Xref passes over both body marker addresses produce no references:

```text
v14: aaa; axt 0x1f814   # no output
v13: aaa; axt 0x21460   # no output
```

Conclusion:

- `const_228` is the first word of the linked-runtime tail marker also targeted
  by `flash_app_end @0x22c`; it is duplicated in the header and body.
- `const_5c` remains the first word of the constant GUID
  `7e6b4cf9-c511-11eb-8282-f74a0c0cef5b`; no runtime body literal use was found.
- `const_b4` remains header-only in the available v13/v14 bodies; no runtime body
  literal use was found.
