package format

import (
	"bytes"
	"encoding/binary"
	"unicode/utf16"
)

// StringEntry is a printable run found by ScanStrings.
type StringEntry struct {
	Offset int64  `json:"offset"`
	Kind   string `json:"kind"` // "ascii" or "utf16le"
	Text   string `json:"text"`
}

// ScanStrings returns ASCII (>= min) and UTF-16LE (>= min codepoints)
// printable runs in buf. Results are deterministic and de-duplicated
// by exact (offset, kind, text) tuple.
func ScanStrings(buf []byte, min int) []StringEntry {
	min = maxInt(min, 4)
	out := make([]StringEntry, 0, 256)

	// ASCII: runs of bytes in [0x20, 0x7E] plus tab.
	asciiStart := -1
	for i, b := range buf {
		if b == 0x09 || (b >= 0x20 && b <= 0x7E) {
			if asciiStart < 0 {
				asciiStart = i
			}
			continue
		}
		if asciiStart >= 0 {
			if i-asciiStart >= min {
				out = append(out, StringEntry{
					Offset: int64(asciiStart),
					Kind:   "ascii",
					Text:   string(buf[asciiStart:i]),
				})
			}
			asciiStart = -1
		}
	}
	if asciiStart >= 0 && len(buf)-asciiStart >= min {
		out = append(out, StringEntry{
			Offset: int64(asciiStart),
			Kind:   "ascii",
			Text:   string(buf[asciiStart:]),
		})
	}

	// UTF-16LE: decode pairs; a run is a sequence of pairs whose
	// codepoints are printable (>= 0x20) or whitespace.
	utfStart := -1
	run := make([]uint16, 0, 64)
	flushUTF := func(end int) {
		if utfStart < 0 {
			return
		}
		if len(run) >= min {
			runes := utf16.Decode(run)
			out = append(out, StringEntry{
				Offset: int64(utfStart),
				Kind:   "utf16le",
				Text:   string(runes),
			})
		}
		utfStart = -1
		run = run[:0]
		_ = end
	}
	for i := 0; i+1 < len(buf); i += 2 {
		u := binary.LittleEndian.Uint16(buf[i : i+2])
		if u == 0 {
			flushUTF(i)
			continue
		}
		r := rune(u)
		// Accept tab, space, and anything in the basic multilingual plane
		// that isn't a control character.
		isPrintable := u == 0x09 || u == 0x0A || u == 0x0D ||
			(u >= 0x20 && u != 0x7F && (r <= 0xFFFD))
		if !isPrintable {
			flushUTF(i)
			continue
		}
		if utfStart < 0 {
			utfStart = i
		}
		run = append(run, u)
	}
	flushUTF(len(buf))

	return out
}

// ExtractAssets writes every embedded asset we detected to outDir.
// Returns the number of files written.
func ExtractAssets(buf []byte, size int64, outDir string, write func(path string, data []byte) error) (int, error) {
	count := 0
	for _, s := range findEmbedded(buf, size) {
		end := s.Offset + s.Size
		if end > size {
			end = size
		}
		data := buf[s.Offset:end]
		path := outDir + "/" + s.Name
		if err := write(path, data); err != nil {
			return count, err
		}
		count++
	}
	_ = bytes.HasPrefix // keep bytes import even if findEmbedded changes
	return count, nil
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}