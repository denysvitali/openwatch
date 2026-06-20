// Package format decodes the H59MA / Oudmon-style firmware container.
//
// The layout is reverse-engineered from the on-disk .bin files
// (H59MA_1.00.13_251230.bin and H59MA_1.00.14_260508.bin) and may not
// cover every variant the vendor ships. Fields that did not decode
// confidently are exposed as NamedField{Offset, Size, RawHex} so callers
// can inspect them without forcing a guess into a typed struct.
//
// The field names exposed here were audited in firmwares/FIRMWARE_ANALYSIS.md §11.
// The prior labels (BuildTime, Unknown32a/b, NonceOrKey, Nonce2, CRC2/3,
// secondary_signature, embedded_jpeg sections) were known to be wrong.
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
)

// Magic is the 4-byte signature that starts every H59MA firmware image.
var Magic = [4]byte{0xE5, 0xC3, 0xBD, 0x81}

// Fixed offsets / sizes that the header uses regardless of firmware size.
// All values verified against both v13 and v14 binaries. See
// firmwares/FIRMWARE_ANALYSIS.md §1 for the corrected field table.
const (
	headerMagicOffset     = 0x00
	headerMagicSize       = 4
	headerLoadSizeOffset  = 0x04
	headerFirmwareSizeOff = 0x08
	headerImageChkaOffset = 0x0C // image-checksum a: 24-bit additive byte-sum

	headerVersionOffset = 0x10
	headerVersionSize   = 24

	headerHWIDOffset = 0x30
	headerHWIDSize   = 16

	headerBlock2Offset    = 0x50 // flags, sdk, body_size, const_5c
	headerConst5COffset   = 0x5C
	headerSignatureAOff   = 0x60
	headerSignatureASize  = 12
	headerFlashAppStart   = 0x6C // u32 LE
	headerFlashAppStart2  = 0x70 // u32 LE (duplicate of 0x6C)
	headerFlashBaseOffset = 0x78 // u32 LE; value is 0x00826000 in observed samples

	headerConstB4Offset  = 0xB4 // u32 LE (constant)
	headerBoardMarkerOff = 0xB0 // u32 LE
	headerSDKStringOff   = 0xB8 // ASCII "sdk#####"

	headerImageDigestOff  = 0x1C4 // 32 bytes — per-build signature/digest
	headerImageDigestSize = 32

	headerConst228Offset  = 0x228 // u32 LE (constant)
	headerFlashAppEndOff  = 0x22C // u32 LE (per-build, follows body_size)

	headerPayloadOffset = 0x450 // start of ARM-Thumb code
)

// MinSize is the smallest file size we'll attempt to parse.
const MinSize = headerPayloadOffset + 16

// Header is the parsed view of the fixed H59MA header.
type Header struct {
	Magic        string `json:"magic"`
	LoadSize     uint32 `json:"load_size"`
	FirmwareSize uint32 `json:"firmware_size"`
	// ImageChkA is a 24-bit additive byte-sum (high byte always 0x00),
	// NOT a CRC32 and not a build timestamp. See FIRMWARE_ANALYSIS.md §1.
	ImageChkA uint32 `json:"image_chk_a"`

	Version string `json:"version"` // e.g. "H59MA_1.00.13_251230"
	HWID    string `json:"hw_id"`   // e.g. "H59MA_V1.0"

	Flags uint32 `json:"flags"`
	SDKID uint32 `json:"sdk_id"`
	// BodySize is the exact size of body.bin = container - 0x450.
	// Was previously mislabeled "unknown32_b".
	BodySize  uint32 `json:"body_size"`
	Const5C   uint32 `json:"const_5c"` // constant 0x7e6b4cf9 — NOT a timestamp
	// SignatureA is the 12-byte constant blob at 0x60..0x6b.
	// The prior 16-byte "signature" was 4 bytes too long and absorbed FlashAppStart.
	SignatureA     string `json:"signature_a_hex"`
	FlashAppStart  uint32 `json:"flash_app_start"`  // 0x6C — same as 0x70
	FlashAppStart2 uint32 `json:"flash_app_start2"` // 0x70 — duplicate of 0x6C
	FlashBase      uint32 `json:"flash_base"`       // 0x78

	BoardMarker uint32 `json:"board_marker"`
	SDKString   string `json:"sdk_string"`
	ConstB4     uint32 `json:"const_b4"` // constant 0x1201a39e

	// ImageDigest is the real per-build 32-byte signature at 0x1c4.
	// The prior "nonce2" read 16 bytes at 0x1c0 (4 bytes early) and
	// absorbed the leading zero padding; it is not a nonce.
	ImageDigest string `json:"image_digest_hex"`

	Const228    uint32 `json:"const_228"`     // constant 0x0e85d101
	FlashAppEnd uint32 `json:"flash_app_end"` // per-build upper bound

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
	Kind   string `json:"kind"`            // header, signature, payload, embedded-asset, unknown
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
	"Field names audited in firmwares/FIRMWARE_ANALYSIS.md §11.",
}

func decodeHeader(buf []byte) (Header, []NamedField) {
	h := Header{
		Magic:        hex.EncodeToString(buf[headerMagicOffset : headerMagicOffset+headerMagicSize]),
		LoadSize:     binary.LittleEndian.Uint32(buf[headerLoadSizeOffset:]),
		FirmwareSize: binary.LittleEndian.Uint32(buf[headerFirmwareSizeOff:]),
		ImageChkA:    binary.LittleEndian.Uint32(buf[headerImageChkaOffset:]),

		Version: readCString(buf[headerVersionOffset : headerVersionOffset+headerVersionSize]),
		HWID:    readCString(buf[headerHWIDOffset : headerHWIDOffset+headerHWIDSize]),

		Flags:          binary.LittleEndian.Uint32(buf[headerBlock2Offset:]),
		SDKID:          binary.LittleEndian.Uint32(buf[headerBlock2Offset+4:]),
		BodySize:       binary.LittleEndian.Uint32(buf[headerBlock2Offset+8:]),
		Const5C:        binary.LittleEndian.Uint32(buf[headerConst5COffset:]),
		SignatureA:     hex.EncodeToString(buf[headerSignatureAOff : headerSignatureAOff+headerSignatureASize]),
		FlashAppStart:  binary.LittleEndian.Uint32(buf[headerFlashAppStart:]),
		FlashAppStart2: binary.LittleEndian.Uint32(buf[headerFlashAppStart2:]),
		FlashBase:      binary.LittleEndian.Uint32(buf[headerFlashBaseOffset:]),

		BoardMarker: binary.LittleEndian.Uint32(buf[headerBoardMarkerOff:]),
		SDKString:   readCString(buf[headerSDKStringOff : headerSDKStringOff+8]),
		ConstB4:     binary.LittleEndian.Uint32(buf[headerConstB4Offset:]),

		ImageDigest: hex.EncodeToString(buf[headerImageDigestOff : headerImageDigestOff+headerImageDigestSize]),

		Const228:    binary.LittleEndian.Uint32(buf[headerConst228Offset:]),
		FlashAppEnd: binary.LittleEndian.Uint32(buf[headerFlashAppEndOff:]),
	}

	fields := []NamedField{
		{0x00, headerMagicSize, "magic", h.Magic, hex.EncodeToString(buf[0x00:0x04]), "H59MA signature E5 C3 BD 81"},
		{0x04, 4, "load_size", h.LoadSize, hex.EncodeToString(buf[0x04:0x08]), "bytes the bootloader copies to RAM (= body_size + 0x400)"},
		{0x08, 4, "firmware_size", h.FirmwareSize, hex.EncodeToString(buf[0x08:0x0C]), "total image size on disk (little-endian u32)"},
		{0x0C, 4, "image_chk_a", h.ImageChkA, hex.EncodeToString(buf[0x0C:0x10]), "24-bit additive byte-sum (high byte always 0x00); NOT CRC32, NOT a timestamp"},
		{0x10, headerVersionSize, "version_string", h.Version, hex.EncodeToString(buf[0x10:0x10+headerVersionSize]), "ASCII, e.g. H59MA_1.00.13_251230"},
		{0x30, headerHWIDSize, "hw_id", h.HWID, hex.EncodeToString(buf[0x30:0x30+headerHWIDSize]), "hardware identifier, e.g. H59MA_V1.0"},
		{0x40, 16, "reserved", nil, hex.EncodeToString(buf[0x40:0x50]), "zero padding"},
		{0x50, 4, "flags", h.Flags, hex.EncodeToString(buf[0x50:0x54]), "build/feature flags"},
		{0x54, 4, "sdk_id", h.SDKID, hex.EncodeToString(buf[0x54:0x58]), "0x00092793 in observed samples"},
		{0x58, 4, "body_size", h.BodySize, hex.EncodeToString(buf[0x58:0x5C]), "exact size of body.bin (= container - 0x450)"},
		{0x5C, 4, "const_5c", h.Const5C, hex.EncodeToString(buf[0x5C:0x60]), "constant 0x7e6b4cf9 (byte-identical across builds); first u32 of GUID 7e6b4cf9-c511-11eb-8282-f74a0c0cef5b; NOT a build timestamp"},
		{0x60, headerSignatureASize, "signature_a", h.SignatureA, hex.EncodeToString(buf[0x60:0x60+headerSignatureASize]), "12-byte constant blob; algorithm unknown"},
		{0x6C, 4, "flash_app_start", h.FlashAppStart, hex.EncodeToString(buf[0x6C:0x70]), "app region start = flash_base + 0x400"},
		{0x70, 4, "flash_app_start2", h.FlashAppStart2, hex.EncodeToString(buf[0x70:0x74]), "duplicate of flash_app_start @ 0x6C"},
		{0x74, 4, "reserved", nil, hex.EncodeToString(buf[0x74:0x78]), "zero"},
		{0x78, 4, "flash_base", h.FlashBase, hex.EncodeToString(buf[0x78:0x7C]), "flash region base (= flash_app_start - 0x400)"},
		{0xB0, 4, "board_marker", h.BoardMarker, hex.EncodeToString(buf[0xB0:0xB4]), "0x00001041 in observed samples"},
		{0xB4, 4, "const_b4", h.ConstB4, hex.EncodeToString(buf[0xB4:0xB8]), "constant 0x1201a39e"},
		{0xB8, 8, "sdk_string", h.SDKString, hex.EncodeToString(buf[0xB8:0xC0]), "ASCII, e.g. sdk#####"},
		{0x1C0, 4, "reserved", nil, hex.EncodeToString(buf[0x1C0:0x1C4]), "zero (leading zero padding of image_digest slot)"},
		{0x1C4, headerImageDigestSize, "image_digest", h.ImageDigest, hex.EncodeToString(buf[0x1C4:0x1C4+headerImageDigestSize]), "per-build 32-byte digest (SHA-256-sized); the real signature; NOT sha256 of any contiguous window of the image"},
		{0x1E4, 68, "reserved", nil, hex.EncodeToString(buf[0x1E4:0x228]), "zero padding"},
		{0x228, 4, "const_228", h.Const228, hex.EncodeToString(buf[0x228:0x22C]), "constant 0x0e85d101"},
		{0x22C, 4, "flash_app_end", h.FlashAppEnd, hex.EncodeToString(buf[0x22C:0x230]), "app region end (= flash_app_start + load_size)"},
		{0x230, 256, "reserved", nil, hex.EncodeToString(buf[0x230:0x330]), "zero padding"},
		{0x330, 16, "erase_marker1", nil, hex.EncodeToString(buf[0x330:0x340]), "all 0xFF"},
		{0x340, 256, "reserved", nil, hex.EncodeToString(buf[0x340:0x440]), "zero padding"},
		{0x440, 16, "erase_marker2", nil, hex.EncodeToString(buf[0x440:0x450]), "all 0xFF (immediately before the body trampoline at 0x450)"},
	}

	return h, fields
}

func deriveSections(buf []byte, size int64) []Section {
	sects := []Section{
		{Name: "header", Offset: 0, Size: headerPayloadOffset, Kind: "header", Note: "decoded H59MA header"},
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

// jpegSOI requires a full JPEG SOI marker (FFD8FF) followed by a plausible
// APPn/JFIF/Exif identifier (E0/E1/DB/EE/etc.). Single-byte FFD8 is not enough
// because the bytes FF D8 also occur as Thumb-2 instruction pairs.
var jpegSOI = []byte{0xFF, 0xD8, 0xFF}

func findEmbedded(buf []byte, size int64) []Section {
	type marker struct {
		needle  []byte
		name    string
		kind    string
		format  string
		minSize int64
		// requireStrongSOI forces a stricter check for formats (JPEG) where
		// the magic bytes overlap with ARM-Thumb instruction pairs.
		requireStrongSOI bool
	}

	markers := []marker{
		{[]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, "embedded_png", "embedded-asset", "png", 64, false},
		{[]byte{'R', 'I', 'F', 'F'}, "embedded_riff", "embedded-asset", "riff", 32, false},
		{jpegSOI, "embedded_jpeg", "embedded-asset", "jpeg", 64, true},
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
			// Strong-SOI guard: for JPEG, the third byte must be a valid
			// marker (E0..EF for APPn, DB for DQT, FE for COM, C0..CF for SOF,
			// C4 for DHT, DA for SOS, 00 for stuffed byte in entropy data,
			// EE for Adobe). The prior heuristic misidentified Thumb-2
			// instruction pairs starting with 0xFF 0xD8 as JPEG SOI.
			if m.requireStrongSOI {
				if abs+3 > size {
					continue
				}
				b3 := buf[abs+3]
				if !isValidJpegMarker(b3) {
					continue
				}
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

// isValidJpegMarker returns true if b is a legal third byte of a JPEG SOI
// sequence (FFD8FFxx). APPn markers are E0..EF, DQT is DB, DHT is C4, SOF
// is C0..CF except C4/C8/CC, DRI is DD, RSTn are D0..D7, SOI is D8, EOI
// is D9, SOS is DA, COM is FE, TEM is 01, and FF is fill. The byte after
// FFD8FF in a real JPEG stream is always one of these.
//
// We accept anything in the set {00, 01, C0..C7, C9..CB, CD..CF, D0..D7,
// D9, DA, DB, DD, DE, DF, E0..EF, FE} to allow APP0 (E0 = JFIF), APP1
// (E1 = Exif), and the common SOF/SOS/SOST markers.
func isValidJpegMarker(b byte) bool {
	switch {
	case b == 0x00, b == 0x01, b == 0xFE:
		return true
	case b >= 0xC0 && b <= 0xC3, b == 0xC5, b == 0xC6, b == 0xC7,
		b == 0xC9, b == 0xCA, b == 0xCB, b == 0xCD, b == 0xCE, b == 0xCF:
		return true
	case b >= 0xD0 && b <= 0xD7, b == 0xD9, b == 0xDA, b == 0xDB,
		b == 0xDD, b == 0xDE, b == 0xDF:
		return true
	case b >= 0xE0 && b <= 0xEF:
		return true
	}
	return false
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
		// Scan for FFD9 (EOI) within cap bytes. We require a leading FF byte
		// to avoid matching arbitrary 0xD9 bytes inside entropy-coded data.
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
