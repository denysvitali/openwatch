# Firmware Container Boundary Evidence

Images:

- `firmwares/H59MA_1.00.13_251230.bin`
- `firmwares/H59MA_1.00.14_260508.bin`
- carved bodies under `firmwares/_re/v13/body.bin` and
  `firmwares/_re/v14/body.bin`

## `flash_app_end @0x22c`

Command:

```sh
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c 'pxw 4 @ 0x22c' firmwares/H59MA_1.00.13_251230.bin
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c 'pxw 4 @ 0x22c' firmwares/H59MA_1.00.14_260508.bin
```

Header field values:

```text
v13 container[0x22c] = 0x00847860
v14 container[0x22c] = 0x00845c14
```

With the shared app load base `0x00826400`, those map to body offsets:

```text
v13 body offset = 0x00847860 - 0x00826400 = 0x21460
v14 body offset = 0x00845c14 - 0x00826400 = 0x1f814

v13 body tail after marker = 0x23440 - 0x21460 = 0x1fe0
v14 body tail after marker = 0x215fc - 0x1f814 = 0x1de8
```

The field therefore is not `flash_app_start + body_size`, nor the end of the
bytes sent over OTA. It points inside the loaded image, near the start of the
linked runtime/library tail.

## Unique Marker At The Boundary

Command:

```sh
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c '/x 01d1850e01000000' firmwares/_re/v14/body.bin
r2 -2 -q -a arm -b 16 -e scr.color=0 \
  -c '/x 01d1850e01000000' firmwares/_re/v13/body.bin
```

The same 8-byte marker occurs exactly where `flash_app_end` points:

```text
v14: 0x0001f814 hit0_0 01d1850e01000000
v13: 0x00021460 hit0_0 01d1850e01000000
```

Bytes around the v14 boundary:

```text
0x0001f7f0  ef75 8300 ff75 8300 0f76 8300 0000 0000
0x0001f800  2976 8300 0000 0000 1f76 8300 9376 8300
0x0001f810  3976 8300 01d1 850e 0100 0000 0000 0000
0x0001f820  6d61 6c6f 6300 6361 6c6c 6f63 0072 6561
```

Bytes around the v13 boundary:

```text
0x00021440  eb75 8300 fb75 8300 0000 0000 1576 8300
0x00021450  0000 0000 0b76 8300 7f76 8300 2576 8300
0x00021460  01d1 850e 0100 0000 0000 0000 6d61 6c6c
0x00021470  6f63 0063 616c 6c6f 6300 7265 616c 6c6f
```

The ASCII after the marker is the runtime allocation string table:

```text
v14 izz~malloc
0x0001a42b  "#malloc %d bytes fail!"
0x0001a7a4  "malloc %d bytes fail!"
0x0001f820  "malloc"

v13 izz~malloc
0x0001b6ab  "#malloc %d bytes fail!"
0x0001bb60  "malloc %d bytes fail!"
0x0002146c  "malloc"
```

## No Runtime Body Xrefs

Searching for the little-endian `flash_app_end` values inside their own carved
bodies returns no hits:

```text
v14 /x 145c8400   # no hits
v13 /x 60788400   # no hits
```

Running an xref pass on the v14 boundary marker also reports no code or data
references:

```text
aaa; axt 0x1f814
# no output
```

Conclusion: `flash_app_end @0x22c` is a per-build boundary pointer into the
loaded image. It identifies a stable linked-runtime tail marker
(`0x0e85d101, 0x00000001`) immediately before allocator/runtime string and
pointer tables. The runtime body does not appear to reference this pointer
directly; any enforcement of the boundary remains a bootloader/apply-path
question outside the OTA body.
