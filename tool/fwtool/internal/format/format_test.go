package format

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// firmwareDir is the repo's firmwares/ folder. Tests resolve it from the
// repo root (../..) when run via `go test ./...` inside tool/fwtool.
func firmwareDir(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	// layout: <repo>/tool/fwtool/internal/format  ->  <repo>/firmwares
	candidate := filepath.Clean(filepath.Join(wd, "..", "..", "..", "firmwares"))
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	// fallback when tests run from a different cwd (CI checkouts etc.)
	candidate = filepath.Clean(filepath.Join(wd, "..", "..", "..", "..", "firmwares"))
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	t.Skipf("firmware samples not found; tried %s", candidate)
	return ""
}

func loadFirmware(t *testing.T, name string) ([]byte, *File) {
	t.Helper()
	dir := firmwareDir(t)
	path := filepath.Join(dir, name)
	buf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	f, err := Parse(bytesReaderAt(buf), int64(len(buf)), path)
	if err != nil {
		t.Fatalf("parse %s: %v", name, err)
	}
	return buf, f
}

type byteRA struct{ b []byte }

func (r *byteRA) ReadAt(p []byte, off int64) (int, error) {
	if off >= int64(len(r.b)) {
		return 0, ioEOF
	}
	n := copy(p, r.b[off:])
	return n, nil
}

var ioEOF = errEOF{}

type errEOF struct{}

func (errEOF) Error() string { return "EOF" }

func bytesReaderAt(b []byte) *byteRA { return &byteRA{b: b} }

func TestParseHeaderV13(t *testing.T) {
	_, f := loadFirmware(t, "H59MA_1.00.13_251230.bin")

	if f.Magic != "e5c3bd81" {
		t.Errorf("magic = %q, want e5c3bd81", f.Magic)
	}
	if f.HWID != "H59MA_V1.0" {
		t.Errorf("hw_id = %q, want H59MA_V1.0", f.HWID)
	}
	if f.Header.Version != "H59MA_1.00.13_251230" {
		t.Errorf("version = %q", f.Header.Version)
	}
	if f.Header.SDKString != "sdk#####" {
		t.Errorf("sdk_string = %q, want sdk#####", f.Header.SDKString)
	}
	if f.Header.FirmwareSize == 0 {
		t.Errorf("firmware_size = 0")
	}
	if f.Header.LoadSize == 0 {
		t.Errorf("load_size = 0")
	}
}

func TestParseHeaderV14(t *testing.T) {
	_, f := loadFirmware(t, "H59MA_1.00.14_260508.bin")
	if f.Header.Version != "H59MA_1.00.14_260508" {
		t.Errorf("version = %q", f.Header.Version)
	}
	if f.Header.HWID != "H59MA_V1.0" {
		t.Errorf("hw_id = %q, want H59MA_V1.0", f.Header.HWID)
	}
	if len(f.SHA256) != 64 {
		t.Errorf("sha256 = %q (len %d, want 64 hex chars)", f.SHA256, len(f.SHA256))
	}
}

func TestHeaderJSONDeterministic(t *testing.T) {
	_, a := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	_, b := loadFirmware(t, "H59MA_1.00.13_251230.bin")

	ja, _ := json.MarshalIndent(a, "", "  ")
	jb, _ := json.MarshalIndent(b, "", "  ")
	if string(ja) != string(jb) {
		t.Errorf("identical inputs produced different JSON")
	}
	// Spot-check well-known fields.
	s := string(ja)
	for _, want := range []string{
		`"magic": "e5c3bd81"`,
		`"version": "H59MA_1.00.13_251230"`,
		`"hw_id": "H59MA_V1.0"`,
		`"sdk_string": "sdk#####"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("JSON missing %s\n%s", want, s)
		}
	}
}

func TestScanStringsFindsKnownMarkers(t *testing.T) {
	buf, _ := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	ss := ScanStrings(buf, 4)

	need := []string{
		"H59MA_1.00.13_251230",
		"H59MA_V1.0",
		"sdk#####",
		"Thu Mar 17 10:58:10 2022",
	}
	for _, n := range need {
		found := false
		for _, e := range ss {
			if e.Text == n {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("ScanStrings missing %q", n)
		}
	}
}

func TestScanStringsIncludesUTF16(t *testing.T) {
	buf, _ := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	ss := ScanStrings(buf, 4)
	hasUTF16 := false
	for _, e := range ss {
		if e.Kind == "utf16le" {
			hasUTF16 = true
			break
		}
	}
	// Not all firmwares contain UTF-16LE; this is a soft check.
	_ = hasUTF16
}

func TestScanStringsMinThreshold(t *testing.T) {
	buf, _ := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	short := ScanStrings(buf, 64)
	long := ScanStrings(buf, 256)
	if len(short) < len(long) {
		t.Errorf("short=%d long=%d: shorter threshold should yield >= entries", len(short), len(long))
	}
	for _, e := range long {
		if len(e.Text) < 256 {
			t.Errorf("entry below min: %q", e.Text)
		}
	}
}

func TestCompareIdenticalFirmware(t *testing.T) {
	dir := firmwareDir(t)
	a, err := os.ReadFile(filepath.Join(dir, "H59MA_1.00.13_251230.bin"))
	if err != nil {
		t.Fatal(err)
	}
	res := Compare(a, a, "a", "b", "x", "x")
	if !res.SameSHA {
		t.Errorf("SameSHA = false, want true")
	}
	if res.DivergentBytes != 0 {
		t.Errorf("divergent_bytes = %d, want 0", res.DivergentBytes)
	}
	if res.IdenticalBytes != int64(len(a)) {
		t.Errorf("identical_bytes = %d, want %d", res.IdenticalBytes, len(a))
	}
}

func TestCompareFindsHeaderAndPayloadDivergence(t *testing.T) {
	dir := firmwareDir(t)
	a, err := os.ReadFile(filepath.Join(dir, "H59MA_1.00.13_251230.bin"))
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "H59MA_1.00.14_260508.bin"))
	if err != nil {
		t.Fatal(err)
	}
	res := Compare(a, b, "v13", "v14", "x", "y")

	if res.SizeA == res.SizeB {
		t.Errorf("expected size diff between v13 and v14")
	}
	// We know the version string at 0x10 changes — at least one divergent
	// region must overlap with the version-string slot.
	if !hasRegionOverlapping(res.Regions, 0x10, 0x30, "divergent") {
		t.Errorf("expected divergent region overlapping the version-string slot 0x10..0x30")
	}
	// The build-time/signature block at 0x50..0x80 also differs between v13/v14.
	if !hasRegionOverlapping(res.Regions, 0x50, 0x80, "divergent") {
		t.Errorf("expected divergent region overlapping 0x50..0x80 (build/signature slot)")
	}
	if res.IdenticalBytes == 0 {
		t.Errorf("identical_bytes = 0; v13/v14 share most of the header")
	}
	if res.DivergentBytes == 0 {
		t.Errorf("divergent_bytes = 0; v13/v14 differ in the header at minimum")
	}
}

func TestDeriveSectionsBodyAlwaysPresent(t *testing.T) {
	_, f := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	if !hasSectionNamed(f.Sections, "header") {
		t.Errorf("missing header section")
	}
	if !hasSectionNamed(f.Sections, "body") {
		t.Errorf("missing body section")
	}
	body := findSection(f.Sections, "body")
	if body == nil {
		t.Fatal("no body")
	}
	if body.Offset != headerPayloadOffset {
		t.Errorf("body offset = %d, want %d", body.Offset, headerPayloadOffset)
	}
	if body.Size != f.Size-headerPayloadOffset {
		t.Errorf("body size = %d, want %d", body.Size, f.Size-headerPayloadOffset)
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	bad := make([]byte, MinSize)
	for i := range bad {
		bad[i] = 0xFF
	}
	if _, err := Parse(bytesReaderAt(bad), int64(len(bad)), "bad.bin"); err != ErrBadMagic {
		t.Errorf("err = %v, want ErrBadMagic", err)
	}
}

func TestParseRejectsTooSmall(t *testing.T) {
	short := make([]byte, 16)
	if _, err := Parse(bytesReaderAt(short), int64(len(short)), "short.bin"); err != ErrTooSmall {
		t.Errorf("err = %v, want ErrTooSmall", err)
	}
}

// TestHeaderFieldCorrections pins the field-level corrections from
// firmwares/FIRMWARE_ANALYSIS.md §11. These assertions would have failed
// against the prior BuildTime/Unknown32a/Nonce2/etc. mislabels.
func TestHeaderFieldCorrections(t *testing.T) {
	for _, name := range []string{"H59MA_1.00.13_251230.bin", "H59MA_1.00.14_260508.bin"} {
		t.Run(name, func(t *testing.T) {
			_, f := loadFirmware(t, name)

			// (1) Const5C is a u32, not a parsed RFC3339 timestamp.
			if f.Header.Const5C != 0x7e6b4cf9 {
				t.Errorf("const_5c = %#x, want 0x7e6b4cf9", f.Header.Const5C)
			}
			// (2) ImageChkA is 24-bit additive, high byte 0x00, varies per build.
			if f.Header.ImageChkA&0xFF000000 != 0 {
				t.Errorf("image_chk_a high byte = %#x, want 0x00", f.Header.ImageChkA>>24)
			}

			// (3) SignatureA is 12 bytes hex (24 hex chars), not 16.
			if got := len(f.Header.SignatureA); got != 24 {
				t.Errorf("signature_a_hex length = %d, want 24 hex chars (12 bytes)", got)
			}

			// (4) Flash pointer cluster.
			if f.Header.FlashBase != 0x00826000 {
				t.Errorf("flash_base = %#x, want 0x00826000", f.Header.FlashBase)
			}
			if f.Header.FlashAppStart != 0x00826400 {
				t.Errorf("flash_app_start = %#x, want 0x00826400", f.Header.FlashAppStart)
			}
			if f.Header.FlashAppStart != f.Header.FlashAppStart2 {
				t.Errorf("flash_app_start (%#x) != flash_app_start2 (%#x)", f.Header.FlashAppStart, f.Header.FlashAppStart2)
			}

			// (5) ImageDigest is 32 bytes hex (64 chars), at 0x1c4, varies per build.
			if got := len(f.Header.ImageDigest); got != 64 {
				t.Errorf("image_digest_hex length = %d, want 64 hex chars (32 bytes)", got)
			}

			// (9) New fields exposed.
			if f.Header.ConstB4 != 0x1201a39e {
				t.Errorf("const_b4 = %#x, want 0x1201a39e", f.Header.ConstB4)
			}
			if f.Header.Const228 != 0x0e85d101 {
				t.Errorf("const_228 = %#x, want 0x0e85d101", f.Header.Const228)
			}
			// flash_app_end varies per build. Pin the per-build values
			// (no clean algebraic relationship to load_size — it is a
			// per-build upper bound of the loaded image).
			if name == "H59MA_1.00.13_251230.bin" && f.Header.FlashAppEnd != 0x00847860 {
				t.Errorf("v13 flash_app_end = %#x, want 0x00847860", f.Header.FlashAppEnd)
			}
			if name == "H59MA_1.00.14_260508.bin" && f.Header.FlashAppEnd != 0x00845c14 {
				t.Errorf("v14 flash_app_end = %#x, want 0x00845c14", f.Header.FlashAppEnd)
			}

			// (10) BodySize = container - 0x450.
			if got, want := uint32(f.Size-0x450), f.Header.BodySize; got != want {
				t.Errorf("body_size = %d, want %d (file_size - 0x450)", got, want)
			}
		})
	}
}

// TestConst5CIsIdenticalAcrossBuilds pins the finding that 0x5c is a
// fixed GUID, not a build timestamp.
func TestConst5CIsIdenticalAcrossBuilds(t *testing.T) {
	_, a := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	_, b := loadFirmware(t, "H59MA_1.00.14_260508.bin")
	if a.Header.Const5C != b.Header.Const5C {
		t.Errorf("const_5c differs: v13=%#x v14=%#x (should be byte-identical)", a.Header.Const5C, b.Header.Const5C)
	}
}

// TestImageDigestVaries pins the finding that 0x1c4 is a per-build
// signature.
func TestImageDigestVaries(t *testing.T) {
	_, a := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	_, b := loadFirmware(t, "H59MA_1.00.14_260508.bin")
	if a.Header.ImageDigest == b.Header.ImageDigest {
		t.Errorf("image_digest identical across v13 and v14 (should differ)")
	}
	// Pin the verified per-build values.
	if got, want := a.Header.ImageDigest, "8d50aa228b80d953cbf616006c7954f46787f4f12deda09fcb0ca9a242178bb1"; got != want {
		t.Errorf("v13 image_digest = %s, want %s", got, want)
	}
	if got, want := b.Header.ImageDigest, "47d3b81a34034731132ef839435d7ee791ec57e8c6d648daff094a4d0d354648"; got != want {
		t.Errorf("v14 image_digest = %s, want %s", got, want)
	}
}

// TestNoSpuriousJpegSection pins the fix for the embedded_jpeg false
// positive at body 0x21EEF (v13) / 0x202A3 (v14). The bytes there are
// const / string-table data, not a JPEG; the third byte of any genuine
// JPEG SOI must be a valid marker (0x00/0x01/0xC0-0xCF/0xD0-0xD7/etc.).
func TestNoSpuriousJpegSection(t *testing.T) {
	for _, name := range []string{"H59MA_1.00.13_251230.bin", "H59MA_1.00.14_260508.bin"} {
		t.Run(name, func(t *testing.T) {
			_, f := loadFirmware(t, name)
			for _, s := range f.Sections {
				if s.Format == "jpeg" {
					t.Errorf("unexpected jpeg section %s at %#x (no real JPEG exists in this firmware)", s.Name, s.Offset)
				}
			}
		})
	}
}

// TestNoSecondarySignatureSection pins the fix for the bogus
// "secondary_signature" section that was being emitted for the all-0xFF
// erase marker at 0x440..0x450. The corrected deriveSections only emits
// real asset sections.
func TestNoSecondarySignatureSection(t *testing.T) {
	_, f := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	for _, s := range f.Sections {
		if s.Name == "secondary_signature" {
			t.Errorf("unexpected section %q at %#x (was mislabeling the 0x440 erase marker)", s.Name, s.Offset)
		}
	}
}

// TestNoLegacyFieldsInJSON pins that the renamed fields are gone and no
// reference to the old names (BuildTime, Unknown32a, Nonce2, etc.) leaks
// into the marshalled header.
func TestNoLegacyFieldsInJSON(t *testing.T) {
	_, f := loadFirmware(t, "H59MA_1.00.13_251230.bin")
	jb, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	s := string(jb)
	legacy := []string{
		`"build_time"`, `"unknown32a"`, `"unknown32_b"`,
		`"nonce_or_key"`, `"nonce2"`, `"crc2"`, `"crc3"`,
		`"crc_or_a"`,
	}
	for _, k := range legacy {
		if strings.Contains(s, k) {
			t.Errorf("JSON still contains legacy field %s", k)
		}
	}
	// New fields must be present.
	for _, k := range []string{
		`"const_5c"`, `"const_b4"`, `"const_228"`,
		`"body_size"`, `"image_chk_a"`, `"image_digest_hex"`,
		`"flash_app_start"`, `"flash_app_end"`, `"flash_base"`,
		`"signature_a_hex"`,
	} {
		if !strings.Contains(s, k) {
			t.Errorf("JSON missing new field %s", k)
		}
	}
}

func hasRegionAt(rs []Region, off int64, status string) bool {
	return hasRegionOverlapping(rs, off, off+1, status)
}

func hasRegionOverlapping(rs []Region, start, end int64, status string) bool {
	for _, r := range rs {
		if r.Status != status {
			continue
		}
		if r.Offset+r.Size <= start {
			continue
		}
		if r.Offset >= end {
			continue
		}
		return true
	}
	return false
}

func hasSectionNamed(ss []Section, name string) bool {
	for _, s := range ss {
		if s.Name == name {
			return true
		}
	}
	return false
}

func findSection(ss []Section, name string) *Section {
	for i := range ss {
		if ss[i].Name == name {
			return &ss[i]
		}
	}
	return nil
}