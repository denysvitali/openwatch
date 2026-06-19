// Package format decodes the H59MA / Oudmon-style firmware container.
//
// The layout is reverse-engineered from the on-disk .bin files
// (H59MA_1.00.13_251230.bin and H59MA_1.00.14_260508.bin) and may not
// cover every variant the vendor ships. Fields that did not decode
// confidently are exposed as NamedField{Offset, Size, RawHex} so callers
// can inspect them without forcing a guess into a typed struct.
package format

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

// Magic is the 4-byte signature that starts every H59MA firmware image.
var Magic = [4]byte{0xE5, 0xC3, 0xBD, 0x81}

// Fixed offsets / sizes that the header uses regardless of firmware size.
const (
	headerMagicOffset       = 0x00
	headerMagicSize         = 4
	headerLoadSizeOffset    = 0x04
	headerFirmwareSizeOff   = 0x08
	headerUnknown32aOffset  = 0x0C

	headerVersionOffset = 0x10
	headerVersionSize   = 24

	headerHWIDOffset = 0x30
	headerHWIDSize   = 16

	headerBlock2Offset = 0x50 // flags, sdk, build, sig, nonce
	headerSigOffset    = 0x60
	headerSigSize      = 16

	headerBoardMarkerOffset = 0xB0
	headerSDKStringOffset   = 0xB8 // ASCII "sdk#####"

	headerNonce2Offset = 0x1C0
	headerNonce2Size   = 16

	headerCRC2Offset = 0x220
	headerCRC3Offset = 0x340

	headerPayloadOffset = 0x450 // start of ARM-Thumb code (best-effort)
)

// MinSize is the smallest file size we'll attempt to parse.
const MinSize = headerPayloadOffset + 16

// Header is the parsed view of the fixed H59MA header.
type Header struct {
	Magic         string `json:"magic"`
	LoadSize      uint32 `json:"load_size"`
	FirmwareSize  uint32 `json:"firmware_size"`
	Unknown32a    uint32 `json:"unknown32a"`

	Version string `json:"version"` // e.g. "H59MA_1.00.13_251230"
	HWID    string `json:"hw_id"`   // e.g. "H59MA_V1.0"

	Flags         uint32 `json:"flags"`
	SDKID         uint32 `json:"sdk_id"`
	Unknown32b    uint32 `json:"unknown32b"`
	BuildTime     uint32 `json:"build_time"`
	CRCOrA        uint32 `json:"crc_or_a"`
	Signature     string `json:"signature_hex"`      // 16 raw bytes hex
	NonceOrKey    string `json:"nonce_or_key_hex"`   // 16 raw bytes hex

	BoardMarker uint32 `json:"board_marker"`
	SDKString   string `json:"sdk_string"`

	Nonce2 string `json:"nonce2_hex"` // 16 raw bytes hex at 0x1C0
	CRC2   uint32 `json:"crc2"`
	CRC3   uint32 `json:"crc3"`

	Fields []NamedField `json:"fields"`
}

// NamedField documents a single decoded region inside the header.
// Used so the JSON output is self-describing and unknown / partially
// decoded slots stay labelled rather than guessed.
type NamedField struct {
	Offset int    `json:"offset"`
	Size   int    `json:"size"`
	Name   string `json:"name"`
	Value  any    `json:"value"`
	Hex    string `json:"hex"`
	Note   string `json:"note,omitempty"`
}

// Section represents a logical partition within the firmware body.
// The on-disk format does not carry an explicit section table, so we
// derive a coarse-grained view from the version/CRC/signature regions
// we *can* identify, and leave the rest as RawBody.
type Section struct {
	Name   string `json:"name"`
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
	Kind   string `json:"kind"`           // header, signature, payload, embedded-asset, unknown
	Format string `json:"format,omitempty"` // png, jpeg, riff, utf16le, ...
	Note   string `json:"note,omitempty"`
}

// File is the parsed view of one firmware image.
type File struct {
	Magic    string    `json:"magic"`
	Filename string    `json:"filename"`
	HWID     string    `json:"hw_id"`
	Size     int64     `json:"size"`
	SHA256   string    `json:"sha256"`
	Header   Header    `json:"header"`
	Sections []Section `json:"sections"`
	Notes    []string  `json:"notes,omitempty"`
}

// ErrTooSmall is returned when the input is smaller than MinSize.
var ErrTooSmall = errors.New("firmware file too small for H59MA header")

// ErrBadMagic is returned when the first 4 bytes don't match Magic.
var ErrBadMagic = errors.New("firmware magic mismatch (expected E5 C3 BD 81)")

// Parse reads a firmware from r and returns its parsed File view.
// filename is recorded for human-readable output.
func Parse(r io.ReaderAt, size int64, filename string) (*File, error) {
	if size < MinSize {
		return nil, ErrTooSmall
	}

	buf := make([]byte, size)
	if _, err := io.ReadFull(io.NewSectionReader(r, 0, size), buf); err != nil {
		return nil, fmt.Errorf("read firmware: %w", err)
	}

	if !bytes.Equal(buf[headerMagicOffset:headerMagicOffset+headerMagicSize], Magic[:]) {
		return nil, ErrBadMagic
	}

	hdr, fields := decodeHeader(buf)
	f := &File{
		Magic:    hex.EncodeToString(Magic[:]),
		Filename: filename,
		HWID:     hdr.HWID,
		Size:     size,
		SHA256:   hex.EncodeToString(sha256Of(buf)),
		Header:   hdr,
		Sections: deriveSections(buf, size),
		Notes:    append([]string(nil), notes...),
	}
	f.Header.Fields = fields
	return f, nil
}

// ParseFile is a convenience wrapper around Parse for filesystem paths.
func ParseFile(path string) (*File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open firmware: %w", err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat firmware: %w", err)
	}
	return Parse(f, st.Size(), path)
}

// MarshalJSON renders the File using indented JSON for readability.
func (f *File) MarshalJSON() ([]byte, error) {
	type alias File
	return json.MarshalIndent((*alias)(f), "", "  ")
}

// notes are appended to every parsed File. Keep them short and stable;
// downstream tooling can rely on the strings.
var notes = []string{
	"Header layout is reverse-engineered from H59MA 1.00.13 / 1.00.14 binaries.",
	"Body offset 0x450 begins an ARM-Thumb code region; payload is opaque.",
	"No explicit section table was found; sections here are derived from marker bytes.",
}

func decodeHeader(buf []byte) (Header, []NamedField) {
	h := Header{
		Magic:        hex.EncodeToString(buf[headerMagicOffset:headerMagicOffset+headerMagicSize]),
		LoadSize:     binary.LittleEndian.Uint32(buf[headerLoadSizeOffset:]),
		FirmwareSize: binary.LittleEndian.Uint32(buf[headerFirmwareSizeOff:]),
		Unknown32a:   binary.LittleEndian.Uint32(buf[headerUnknown32aOffset:]),
		Version:      readCString(buf[headerVersionOffset : headerVersionOffset+headerVersionSize]),
		HWID:         readCString(buf[headerHWIDOffset : headerHWIDOffset+headerHWIDSize]),
		Flags:        binary.LittleEndian.Uint32(buf[headerBlock2Offset:]),
		SDKID:        binary.LittleEndian.Uint32(buf[headerBlock2Offset+4:]),
		Unknown32b:   binary.LittleEndian.Uint32(buf[headerBlock2Offset+8:]),
		BuildTime:    binary.LittleEndian.Uint32(buf[headerBlock2Offset+12:]),
		CRCOrA:       binary.LittleEndian.Uint32(buf[headerBlock2Offset+16:]),
		Signature:    hex.EncodeToString(buf[headerSigOffset : headerSigOffset+headerSigSize]),
		NonceOrKey:   hex.EncodeToString(buf[headerSigOffset+headerSigSize : headerSigOffset+headerSigSize+16]),
		BoardMarker:  binary.LittleEndian.Uint32(buf[headerBoardMarkerOffset:]),
		SDKString:    readCString(buf[headerSDKStringOffset : headerSDKStringOffset+8]),
		Nonce2:       hex.EncodeToString(buf[headerNonce2Offset : headerNonce2Offset+headerNonce2Size]),
		CRC2:         binary.LittleEndian.Uint32(buf[headerCRC2Offset:]),
		CRC3:         binary.LittleEndian.Uint32(buf[headerCRC3Offset:]),
	}

	fields := []NamedField{
		{0x00, 4, "magic", h.Magic, hex.EncodeToString(buf[0x00:0x04]), "H59MA signature E5 C3 BD 81"},
		{0x04, 4, "load_size", h.LoadSize, hex.EncodeToString(buf[0x04:0x08]), "bytes the bootloader copies to RAM"},
		{0x08, 4, "firmware_size", h.FirmwareSize, hex.EncodeToString(buf[0x08:0x0C]), "total image size on disk (little-endian u32)"},
		{0x0C, 4, "unknown32_a", h.Unknown32a, hex.EncodeToString(buf[0x0C:0x10]), "always 0x00CE90EE in observed samples"},
		{0x10, headerVersionSize, "version_string", h.Version, hex.EncodeToString(buf[0x10:0x10+headerVersionSize]), "ASCII, e.g. H59MA_1.00.13_251230"},
		{0x30, headerHWIDSize, "hw_id", h.HWID, hex.EncodeToString(buf[0x30:0x30+headerHWIDSize]), "hardware identifier, e.g. H59MA_V1.0"},
		{0x50, 4, "flags", h.Flags, hex.EncodeToString(buf[0x50:0x54]), "feature flags (semantics unknown)"},
		{0x54, 4, "sdk_id", h.SDKID, hex.EncodeToString(buf[0x54:0x58]), "0x00092793 in observed samples"},
		{0x58, 4, "unknown32_b", h.Unknown32b, hex.EncodeToString(buf[0x58:0x5C]), ""},
		{0x5C, 4, "build_time_unix", time.Unix(int64(h.BuildTime), 0).UTC().Format(time.RFC3339), hex.EncodeToString(buf[0x5C:0x60]), "0x? - interpret as little-endian unix timestamp or counter"},
		{0x60, headerSigSize, "signature_a", h.Signature, hex.EncodeToString(buf[0x60:0x60+headerSigSize]), "0x? - 16-byte signature-like block; algorithm unknown"},
		{0x70, 16, "nonce_or_key", h.NonceOrKey, hex.EncodeToString(buf[0x70:0x80]), "0x? - looks like a key/nonce; do not interpret"},
		{0xB0, 4, "board_marker", h.BoardMarker, hex.EncodeToString(buf[0xB0:0xB4]), "0x00001041 in observed samples"},
		{0xB8, 8, "sdk_string", h.SDKString, hex.EncodeToString(buf[0xB8:0xC0]), "ASCII, e.g. sdk#####"},
		{0x1C0, headerNonce2Size, "nonce2", h.Nonce2, hex.EncodeToString(buf[0x1C0:0x1C0+headerNonce2Size]), "0x? - 16-byte block before payload start"},
		{0x220, 4, "crc2", h.CRC2, hex.EncodeToString(buf[0x220:0x224]), "0x? - checksum slot"},
		{0x340, 4, "crc3", h.CRC3, hex.EncodeToString(buf[0x340:0x344]), "0x? - checksum slot"},
	}

	return h, fields
}

func deriveSections(buf []byte, size int64) []Section {
	sects := []Section{
		{Name: "header", Offset: 0, Size: headerPayloadOffset, Kind: "header", Note: "decoded H59MA header"},
	}

	// Mark the secondary 16-byte signature-like block we noticed at 0x440
	// (immediately before the body). Best-effort: only emit when it differs
	// from the zero block, otherwise it's just padding.
	if size > 0x460 {
		candidate := buf[0x440:0x450]
		if !bytes.Equal(candidate, make([]byte, 16)) {
			sects = append(sects, Section{
				Name: "secondary_signature", Offset: 0x440, Size: 16,
				Kind: "signature", Note: "0x? — 16-byte block at body boundary",
			})
		}
	}

	// Body: anything from headerPayloadOffset to EOF.
	bodyOffset := int64(headerPayloadOffset)
	if bodyOffset < size {
		sects = append(sects, Section{
			Name: "body", Offset: bodyOffset, Size: size - bodyOffset,
			Kind: "payload", Note: "ARM-Thumb code + embedded assets",
		})
	}

	// Embedded-asset scan: locate PNG / JPEG / RIFF / "version" / "signature"
	// markers anywhere in the file and add a section for each.
	for _, m := range findEmbedded(buf, size) {
		sects = append(sects, m)
	}

	return sects
}

func findEmbedded(buf []byte, size int64) []Section {
	type marker struct {
		needle  []byte
		name    string
		kind    string
		format  string
		minSize int64
	}

	markers := []marker{
		{[]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, "embedded_png", "embedded-asset", "png", 64},
		{[]byte{'R', 'I', 'F', 'F'}, "embedded_riff", "embedded-asset", "riff", 32},
		{[]byte{0xFF, 0xD8, 0xFF}, "embedded_jpeg", "embedded-asset", "jpeg", 64},
	}

	var out []Section
	for _, m := range markers {
		off := 0
		for {
			idx := bytes.Index(buf[off:], m.needle)
			if idx < 0 {
				break
			}
			abs := int64(off + idx)
			off += idx + len(m.needle)
			if abs >= size {
				break
			}
			end := guessAssetEnd(buf, abs, size, m.format)
			if end-abs < m.minSize {
				continue
			}
			out = append(out, Section{
				Name:   fmt.Sprintf("%s@0x%X", m.name, abs),
				Offset: abs,
				Size:   end - abs,
				Kind:   m.kind,
				Format: m.format,
			})
		}
	}
	return out
}

// guessAssetEnd returns the best-effort end offset for an asset that
// starts at start. For PNG we trust the IHDR width/height; for RIFF we
// trust the size field; for JPEG we scan for the next FFD9 marker.
// If nothing confident is found, we cap at 1 MiB to avoid runaway sections.
func guessAssetEnd(buf []byte, start, size int64, format string) int64 {
	const cap = int64(1 << 20)
	switch format {
	case "png":
		if size-start >= 24 {
			// IHDR width/height are at +16 and +20 from the PNG sig.
			w := binary.BigEndian.Uint32(buf[start+16 : start+20])
			h := binary.BigEndian.Uint32(buf[start+20 : start+24])
			// Heuristic: width*height*4 + 1 KiB headroom. Not exact, but
			// matches the rough compressed size of a UI bitmap.
			est := int64(w)*int64(h)*4 + 1024
			end := start + est
			if end > size {
				end = size
			}
			if end-start > cap {
				end = start + cap
			}
			return end
		}
	case "riff":
		if size-start >= 8 {
			chunk := int64(binary.LittleEndian.Uint32(buf[start+4 : start+8]))
			end := start + 8 + chunk
			if end > size {
				end = size
			}
			if end-start > cap {
				end = start + cap
			}
			return end
		}
	case "jpeg":
		// Scan for FFD9 (EOI) within cap bytes.
		limit := start + cap
		if limit > size {
			limit = size
		}
		for i := start + 3; i+1 < limit; i++ {
			if buf[i] == 0xFF && buf[i+1] == 0xD9 {
				return i + 2
			}
		}
	}
	if size-start > cap {
		return start + cap
	}
	return size
}

func readCString(b []byte) string {
	n := bytes.IndexByte(b, 0)
	if n < 0 {
		n = len(b)
	}
	return strings.TrimRight(string(b[:n]), "\x00")
}

func sha256Of(b []byte) []byte {
	sum := sha256.Sum256(b)
	return sum[:]
}