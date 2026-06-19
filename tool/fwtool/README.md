# fwtool

A small Go unpacker for H59MA / Oudmon-style firmware images.

It parses the fixed-size container header (magic, version, hw_id, signatures,
CRCs), derives a coarse section view, and extracts printable strings and any
embedded PNG / JPEG / RIFF assets it can locate.

## Layout

```
tool/fwtool/
├── Makefile
├── README.md
├── go.mod
├── cmd/fwtool/        # CLI entrypoint (stdlib flag, no external deps)
└── internal/format/   # H59MA format structs + parser + tests
```

## Build

```sh
make build          # → ./fwtool
go test ./...       # run all tests
```

Go 1.22+ is required. No third-party dependencies.

## Usage

### info — show parsed header + sections

```sh
./fwtool info ../../firmwares/H59MA_1.00.13_251230.bin
./fwtool info -json ../../firmwares/H59MA_1.00.13_251230.bin   # machine-readable
```

Output:

```
file:        ../../firmwares/H59MA_1.00.13_251230.bin
magic:       e5c3bd81
size:        145552 bytes
sha256:      …
hw_id:       H59MA_V1.0

Header fields:
  0x0000  magic             = e5c3bd81
  0x0004  load_size         = 145400
  0x0008  firmware_size     = 145552
  …
  0x0010  version_string    = H59MA_1.00.13_251230
  0x0030  hw_id             = H59MA_V1.0
  0x00B8  sdk_string        = sdk#####
  …

Sections:
  0x000000..0x000450  header                kind=header
  0x000450..0x0238D0  body                  kind=payload  ; ARM-Thumb code + assets
```

### unpack — extract everything we can identify

```sh
./fwtool unpack ../../firmwares/H59MA_1.00.13_251230.bin -o out_v13
```

Produces:

- `out_v13/header.json`  — full parsed view, machine-readable
- `out_v13/strings.txt`  — ASCII + UTF-16LE printable runs (>= 4 chars)
- `out_v13/assets/*`     — any embedded PNG / JPEG / RIFF we detected
- `out_v13/body.bin`     — the raw payload bytes

### strings — just printable runs

```sh
./fwtool strings ../../firmwares/H59MA_1.00.13_251230.bin
./fwtool strings -min 8 ../../firmwares/H59MA_1.00.13_251230.bin
./fwtool strings -json ../../firmwares/H59MA_1.00.13_251230.bin
```

### compare — diff two firmwares

```sh
./fwtool compare ../../firmwares/H59MA_1.00.13_251230.bin \
                 ../../firmwares/H59MA_1.00.14_260508.bin
```

Emits a list of identical / divergent regions with byte counts and SHA-256.

## Status

The header layout and section derivation are reverse-engineered from the two
firmwares shipped in `firmwares/`. Fields that did not decode confidently are
labelled `0x?` in the `note` column — we do **not** invent semantics. Add new
fields by extending `decodeHeader` in `internal/format/format.go`.