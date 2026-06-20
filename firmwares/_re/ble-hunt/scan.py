#!/usr/bin/env python3
"""Scan H59MA firmware binaries for BLE protocol constants."""
import os, sys, struct, json

OUT = os.path.dirname(os.path.abspath(__file__))

# (tag, byte_pattern)
MAGICS = [
    ("header_magic_e5c3bd81", bytes.fromhex("81bdc3e5")),  # LE u32 E5C3BD81
    ("channelB_magic_0xbc",   bytes.fromhex("bc")),        # single byte 0xBC
]

# BLE UUIDs as 16-bit LE (Nordic-style short) and full byte patterns.
# Short 16-bit UUID => 0x????0000-0000-1000-8000-00805f9b34fb (BT SIG base).
# But often stored as raw little-endian u16. Search both encodings.
UUID_PATTERNS = [
    # Nordic UART Service (Channel A, common)
    ("uuid_6e400002_raw_le",  bytes.fromhex("0200406e")),  # 0x6E40 LE u16 = 02 00 40 6e? actually 0x6e40 LE = 40 6e
    ("uuid_6e40_le_u16",      bytes.fromhex("406e")),
    ("uuid_6e400003_le_u16",  bytes.fromhex("036e")),  # LE u16 = 03 00 40 6e? -> 16bit only 0x6E40 family
    ("uuid_6e400003_le_u32",  bytes.fromhex("0300406e")),
    ("uuid_fff0_le_u16",      bytes.fromhex("f0ff")),
    ("uuid_fff0_le_u32",      bytes.fromhex("f0000000")),  # not typical
    # H59MA Channel B service
    ("uuid_de5bf728_le_u32",  bytes.fromhex("28f75bde")),
    ("uuid_de5bf729_le_u32",  bytes.fromhex("29f75bde")),
    ("uuid_de5bf72a_le_u32",  bytes.fromhex("2af75bde")),
    ("uuid_de5bf728_raw",     bytes.fromhex("de5bf728")),  # big-endian-ish raw
    # Device Info 0x180A and chars
    ("uuid_180a_le_u16",      bytes.fromhex("0a18")),
    ("uuid_2a26_le_u16",      bytes.fromhex("262a")),
    ("uuid_2a27_le_u16",      bytes.fromhex("272a")),
    ("uuid_2a28_le_u16",      bytes.fromhex("282a")),
    ("uuid_180a_le_u32",      bytes.fromhex("0a000000")),  # 16-bit zero-padded
    ("uuid_2a26_le_u32",      bytes.fromhex("26000000")),
    ("uuid_2902_le_u16",      bytes.fromhex("0229")),
]

# Opcodes to search as single bytes
OPCODE_BYTES = [0x01, 0x02, 0x10, 0x12, 0x1d, 0x1f, 0x29, 0x2a, 0x2f, 0x32, 0x3c, 0x3d, 0x3f, 0x73, 0x78, 0xbc]

# CRC16 poly constants to look for as LE u16
CRC_CONSTS = [
    ("crc16_a001_le",  bytes.fromhex("01a0")),
    ("crc16_1021_le",  bytes.fromhex("2110")),
]

# 256-entry u8 table for CRC16 (each entry = 256 bytes, often aligned)
# 256-byte CRC tables usually preceded/followed by a magic or a reference.
# We'll detect by structure later.

TARGETS = [
    ("/home/workspace/git/openwatch/firmwares/H59MA_1.00.13_251230.bin",   "v13_full"),
    ("/home/workspace/git/openwatch/firmwares/H59MA_1.00.14_260508.bin",   "v14_full"),
    ("/home/workspace/git/openwatch/firmwares/_re/v13/body.bin",           "v13_body"),
    ("/home/workspace/git/openwatch/firmwares/_re/v14/body.bin",           "v14_body"),
]

def find_all(data, pat):
    out = []
    start = 0
    while True:
        i = data.find(pat, start)
        if i < 0: break
        out.append(i)
        start = i + 1
    return out

def hexdump(data, base, n=32):
    """Hex dump 32 bytes starting at base."""
    end = min(base + n, len(data))
    chunk = data[base:end]
    return " ".join(f"{b:02x}" for b in chunk)

results = {}

for path, tag in TARGETS:
    if not os.path.exists(path):
        continue
    with open(path, "rb") as f:
        data = f.read()
    res = {}
    # Magics
    for name, pat in MAGICS:
        res.setdefault(name, []).extend([(o, hexdump(data, o, 32)) for o in find_all(data, pat)])
    # UUIDs
    for name, pat in UUID_PATTERNS:
        offs = find_all(data, pat)
        if offs:
            res[name] = [(o, hexdump(data, o, 32)) for o in offs]
    # Opcode bytes (single-byte, expect many hits — show first 20 + total)
    for op in OPCODE_BYTES:
        pat = bytes([op])
        offs = find_all(data, pat)
        if offs:
            # show first 10 + count + last offset
            sample = [(o, hexdump(data, o, 16)) for o in offs[:10]]
            res[f"opcode_0x{op:02x}"] = {"count": len(offs), "first": offs[:10], "last": offs[-1] if offs else None, "sample": sample}
    # CRC constants
    for name, pat in CRC_CONSTS:
        offs = find_all(data, pat)
        if offs:
            res[name] = [(o, hexdump(data, o, 32)) for o in offs]
    results[tag] = {"size": len(data), "hits": res}

# Save
out_path = os.path.join(OUT, "scan_results.json")
with open(out_path, "w") as f:
    json.dump(results, f, indent=2)

# Print compact summary
print(f"Wrote {out_path}")
for tag, info in results.items():
    print(f"\n=== {tag} (size={info['size']}) ===")
    for name, hits in info["hits"].items():
        if isinstance(hits, dict):
            print(f"  {name}: count={hits['count']}, first5={hits['first'][:5]}, last={hits['last']}")
        else:
            if hits:
                print(f"  {name}: {len(hits)} hit(s) at offsets {[h[0] for h in hits[:8]]}")
            else:
                print(f"  {name}: 0 hits")
