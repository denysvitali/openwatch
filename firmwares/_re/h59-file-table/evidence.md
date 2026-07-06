# H59MA v14 Channel-B File Table (`0x41`/`0x42`/`0x43`)

Scope: H59MA v14 OTA body at `firmwares/_re/v14/body.bin`. Offsets are body
offsets; add `0x826400` for the runtime address.

Commands used:

```bash
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'pd 260 @ 0xac40' firmwares/_re/v14/body.bin
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'pd 240 @ 0xadb8' firmwares/_re/v14/body.bin
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'pd 240 @ 0xafba' firmwares/_re/v14/body.bin
r2 -2 -q -a arm -b 16 -e asm.cpu=cortex -e scr.color=0 \
  -c 'px 0x20 @ 0xae1c' firmwares/_re/v14/body.bin
```

## Handler Dispatch

`FUN_008311b8` at body `0xadb8` checks the Channel-B command byte:

- `0x41`: builds a file-list response.
- `0x43`: calls the file operation helper at `0xacc8`.
- Other values return immediately from this local handler. The normal
  first-stage dispatcher bypasses async storage for on-wire `0x46`; if an
  internal path seeds `cmd = 0x46` into the async worker, this local handler
  still returns without calling the `0x43` operation helper.

For `0x41`, the handler copies the 4-byte request value to stack state, sets
`rsp[0] = 0`, then loops while `FUN_008313ba` (`0xafba`) returns a record and
the count is below 10. Each record is formatted by `FUN_0083105a` (`0xac5a`)
and appended after the count byte. The response is sent as command `0x42`.

Wire shape:

```text
0x42 payload:
  byte 0      record count (0..10)
  byte 1..N   length-prefixed records
```

## Record Formatter

`FUN_0083105a` at `0xac5a` formats one table record:

- Initializes output record length byte to `2`.
- Copies source record byte `6` to output byte `1` as `recordType`.
- Appends fields by calling `FUN_00830fa0` (`0xaba0`).
- Returns the final inclusive record length.

Wire shape:

```text
record[0]      recordLen, including recordLen and recordType
record[1]      recordType
record[2..end] field TLVs

field[0]       fieldLen, including fieldLen and fieldId
field[1]       fieldId
field[2..end]  raw value bytes
```

Field-id sets are copied from inline data at `0xae1c`:

```text
0xae1c: 01 02 03 04 05 06 07 08 09 0d 13 00
0xae28: 01 02 04 07 08 09 00 00
```

Record types `0x04`, `0x07`, and `0x08` use the 11-id set
`01 02 03 04 05 06 07 08 09 0d 13`. All other record types use
`01 02 04 07 08 09`.

`FUN_00830fa0` initializes each field length to `2`, writes the field id, then
copies 1, 2, or 4 value bytes depending on the field-specific switch case. Static
analysis does not prove user-facing field names, so OpenWatch decodes ids and
raw values generically.

## File Operation / Chunking

`FUN_008310c8` at `0xacc8` handles `0x43` operation payloads. The operation
uses byte `0` as a selector and bytes `1..4` as a little-endian record id. When
the record exists, the watch emits:

- `0x44` metadata, 6-byte payload:
  `[0x00, chunkCount u16LE, meta3, 0x01, 0x11]`.
- `0x45` chunk frames shaped `[chunkIndex1Based, 0x00, data...]`.

The chunk loop caps each chunk's data body at `0x1f4` bytes and sends payload
length `dataLen + 2`.

Other `0x44` status forms:

- Invalid selector (`selector - 1 >= 0xee`): `[0x02, selector]`.
- Record id not found: `[0x01, selector, recordId u32LE]`.

The remaining `0x44` metadata byte at offset 3 is copied from source-record
offset 4, but static analysis does not prove a user-facing meaning.
