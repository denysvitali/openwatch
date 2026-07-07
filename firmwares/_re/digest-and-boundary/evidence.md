# H59MA Container `image_digest` and `flash_app_end` Boundary — radare2 Evidence

Firmware targets:

| Version | Container | Load base used in r2 |
|---|---|---|
| v13 | `firmwares/H59MA_1.00.13_251230.bin` | `0x00826000` |
| v14 | `firmwares/H59MA_1.00.14_260508.bin` | `0x00826000` |

Radare2 invocation (container loaded at flash base):

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c '<cmd>' firmwares/H59MA_1.00.14_260508.bin
```

## 1. `image_digest` at container offset `0x1c4` is not referenced by the app body

The 32-byte per-build digest lives in the container header:

```text
px 48 @ 0x008261c0   # v14
0x008261c0  0000 0000 47d3 b81a 3403 4731 132e f839  ....G...4.G1...9
0x008261d0  435d 7ee7 91ec 57e8 c6d6 48da ff09 4a4d  C]~...W...H...JM
0x008261e0  0d35 4648 0000 0000 0000 0000 0000 0000  .5FH...........
```

Searching the full container image for the digest-region pointer `0x008261c4`
finds **zero code/data references** in either build:

```text
/x c4268000   # v13 -> 0 hits
/x c4268000   # v14 -> 0 hits
```

Searching for the digest value bytes themselves also returns no hits outside the
header slot:

```text
# v14 digest value 47d3b81a34034731...
/x 1ab8d347 ...   # no hits in body/code
```

Cross-reference analysis (`aaa; axt`) on the digest slot reports no callers from
within the loaded image.

Conclusion: the runtime app body does not parse or validate the 32-byte
`image_digest`. If the digest is enforced at all, it happens in the
bootloader/ROM region below `0x00826400`, which is not present in the OTA slice.

## 2. OTA path stages the digest but never checks it

The v14 OTA data-packet handler (`ota_cmd_write_data_packet`, device
`0x0082f240`) copies the first `0x50` bytes to a stack buffer, checks the first
word against the container magic `0x81bdc3e5`, then stages everything from file
offset `0x50` onward. The digest at file offset `0x1c4` therefore lands in the
staged image, but no subsequent function reads it back.

`ota_cmd_check_complete` (`0x0082f3e2`) only verifies:

```text
0x0082f3e6  5039   subs r1, 0x50
0x0082f3e8  8b42   cmp r3, r1
```

i.e. `written_bytes == expected_size - 0x50`. The same `subs r1, 0x50; cmp r3,
r1` pattern is found at v13 `0x0082f42e`.

No hash-comparison or signature-check basic block precedes the state-4
completion transition.

## 3. `flash_app_end` points `0x50` bytes before a boundary marker

Container field at `0x22c`:

| Build | `flash_app_end` value | Marker address (`+0x50`) |
|---|---|---|
| v13 | `0x00847860` | `0x008478b0` |
| v14 | `0x00845c14` | `0x00845c64` |

The marker bytes at the `+0x50` position are identical in both builds:

```text
0x00845c60  3976 8300 01d1 850e 0100 0000 0000 0000  9v..............
0x008478b0  01d1 850e 0100 0000 ...                   (v13)
```

Radare2 finds **no xrefs** from code to either the `flash_app_end` value or the
marker address:

```text
axt @ 0x00845c64   # v14 -> no xrefs
axt @ 0x008478b0   # v13 -> no xrefs
```

The only xref to `flash_app_end` is the header field itself (`0x0082622c`).

Interpretation: `flash_app_end` and the `0x0e85d101,0x00000001` marker are
bootloader/runtime-boundary metadata. The app body does not enforce them; they
likely tell the bootloader where the application region ends and where the
linked runtime tail (`malloc`/`calloc`/… strings begin immediately after the
marker) starts.

## 4. `const_b4` is header-only metadata

`const_b4 = 0x1201a39e` at container `0xb4` appears exactly once in each
container — at the header field itself:

```text
/x 9ea30112   # v13 -> 0x008260b4 only
/x 9ea30112   # v14 -> 0x008260b4 only
```

No code or data reference to this value was found. It is therefore a build
toolchain constant or board identifier, not a runtime-checked value.

## 5. `image_chk_a` additive checksum re-verified

The `0x0c` checksum is `sum(container[0x50:]) & 0xffffffff`:

| Build | Header `@0x0c` | `sum(container[0x50:])` | Match |
|---|---|---|---|
| v13 | `0x00ce90ee` | `0x00ce90ee` | ✅ |
| v14 | `0x00c43671` | `0x00c43671` | ✅ |

Starting at `0x60` (as earlier notes once suggested) does **not** match.

## Commands run

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'px 48 @ 0x008261c0' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c '/x c4268000' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c '/x 01d1850e01000000' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'aaa; axt @ 0x00845c64' firmwares/H59MA_1.00.14_260508.bin

r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 -m 0x00826000 \
   -c 'pd 20 @ 0x0082f3e2' firmwares/H59MA_1.00.14_260508.bin
```

Python checksum verification:

```python
d = open('firmwares/H59MA_1.00.14_260508.bin', 'rb').read()
expected = int.from_bytes(d[0x0c:0x10], 'little')
assert sum(d[0x50:]) & 0xffffffff == expected
```

## Bottom line

- `image_digest` is staged by OTA but not validated by the H59MA v13/v14 app
  body. The algorithm remains unknown; a full lower-flash/bootloader dump would
  be required to find the verification path.
- `flash_app_end` and the `0x0e85d101` marker are boundary metadata, not
  runtime-checked by the app body.
- `const_b4` is header-only and unused by the app body.
