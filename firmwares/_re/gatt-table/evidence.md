# GATT Table radare2 Evidence

Date: 2026-07-05

Scope: H59MA v13/v14 OTA bodies at `firmwares/_re/v13/body.bin` and
`firmwares/_re/v14/body.bin`. Offsets are body offsets.

External reference used only for field naming: Realtek-derived AOSP source
defines GATT server tables as `T_ATTRIB_APPL` initializers with fields named
`wFlags`, `bTypeValue`, `bValueLen`, `pValueContext`, and `wPermissions`:
https://android.googlesource.com/platform/hardware/google/atv/refDesignRcu/realtek/+/refs/heads/main/src/ble/profile/server/voice_service.c

## Inline 0x1c Attribute Records

Command:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'px 0x1c @ 0x1f026; px 0x1c @ 0x1f042; px 0x1c @ 0x1f176; px 0x1c @ 0x1f1ca' \
  firmwares/_re/v14/body.bin
```

Output:

```text
0x0001f026  8200 0208 0028 0a18 0000 0000 0000 0000
0x0001f036  0000 0000 0200 0000 0000 0100

0x0001f042  0000 0200 0328 0200 0000 0000 0000 0000
0x0001f052  0000 0000 0100 0000 0000 0100

0x0001f176  0000 0500 c75d 2a01 e365 26af 474e 11d7
0x0001f186  2af7 5bde 0000 0000 0000 1000

0x0001f1ca  0000 1200 0229 0000 0000 0000 0000 0000
0x0001f1da  0000 0000 0200 0000 0000 1100
```

Interpretation:

- `0x1f026`: 16-bit Device Information primary service. ATT UUID `0x2800` is
  at record `+0x04`; inline service UUID `0x180a` is at `+0x06`;
  `bValueLen = 0x0002` at `+0x14`; final permission word `0x0001` at `+0x1a`.
- `0x1f042`: characteristic declaration. ATT UUID `0x2803` is at `+0x04`;
  properties byte `0x02` is at `+0x06`; `bValueLen = 1`; permission word
  `0x0001`.
- `0x1f176`: 128-bit Channel-B write characteristic value. The `0x0005` word
  marks the 128-bit inline UUID form; the UUID starts at `+0x04`;
  `bValueLen = 0`; final permission word `0x0010`.
- `0x1f1ca`: CCCD. ATT UUID `0x2902` is at `+0x04`; `bValueLen = 2`;
  final permission word `0x0011`.

## 128-bit Primary Service UUID Pointers

Command:

```sh
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'px 0x10 @ 0x1f130; px 0x1a @ 0x1f140; px 0x10 @ 0x1f1f4; px 0x1a @ 0x1f204' \
  firmwares/_re/v14/body.bin
```

Output:

```text
0x0001f130  c75d 2a01 e365 26af 474e 11d7 28f7 5bde

0x0001f140  0008 0028 0000 0000 0000 0000 0000 0000
0x0001f150  0000 1000 3055 8400 0100

0x0001f1f4  9eca dc24 0ee5 a9e0 93f3 a3b5 f0ff 406e

0x0001f204  0008 0028 0000 0000 0000 0000 0000 0000
0x0001f214  0000 1000 f455 8400 0100
```

The 16-byte UUID blobs are stored immediately before compact service entries.
The service entries have ATT UUID `0x2800`, `bValueLen = 0x10`, and
`pValueContext` pointing back to the blob:

| Service | UUID blob | Entry | `pValueContext` | Body offset |
|---|---:|---:|---:|---:|
| Channel B `de5bf728` | `0x1f130` | `0x1f140` | `0x00845530` | `0x1f130` |
| Channel A `6e40fff0` | `0x1f1f4` | `0x1f204` | `0x008455f4` | `0x1f1f4` |

Address conversion uses the app load base `0x00826400`.

v13 has the same pattern:

```text
0x00020d7c  c75d 2a01 e365 26af 474e 11d7 28f7 5bde
0x00020d8c  0008 0028 ... 1000 7c71 8400 0100

0x00020e40  9eca dc24 0ee5 a9e0 93f3 a3b5 f0ff 406e
0x00020e50  0008 0028 ... 1000 4072 8400 0100
```

`0x0084717c - 0x00826400 = 0x20d7c`, and
`0x00847240 - 0x00826400 = 0x20e40`.

## Service Callback Blocks

The service tables are separated by callback blocks rather than a single
uninterrupted record array. v14 examples:

```text
0x0001f122  0000 6fe5 8200 0000 0000 0000 0000
0x0001f1e6  0000 29e7 8200 53e7 8200 b9e7 8200
0x0001f2aa  0000 51e8 8200 7be8 8200 cfe8 8200
0x0001f3b2  a3e9 8200 4dea 8200 bbea 8200
```

Interpreted as Realtek service callback pointers:

| Service | Callback block | Read cb | Write cb | CCCD cb |
|---|---:|---:|---:|---:|
| Device Information | `0x1f122` | `0x0082e56f` | `0x00000000` | `0x00000000` |
| Channel B | `0x1f1e6` | `0x0082e729` | `0x0082e753` | `0x0082e7b9` |
| Channel A | `0x1f2aa` | `0x0082e851` | `0x0082e87b` | `0x0082e8cf` |
| fee7 | `0x1f3b2` | `0x0082e9a3` | `0x0082ea4d` | `0x0082eabb` |

The fee7 callback block starts at `0x1f3b2`, immediately after the final fee7
CCCD record; the CRC-16 table begins at `0x1f3c0`.
