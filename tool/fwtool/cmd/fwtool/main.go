// Command fwtool is a Go unpacker for H59MA firmware images.
//
// Usage:
//
//	fwtool info    <file>
//	fwtool unpack  <file> -o <dir>
//	fwtool strings <file>
//	fwtool compare <a> <b>
//
// See README.md for details.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/openwatch/fwtool/internal/format"
)

const usage = `fwtool — H59MA firmware unpacker

Usage:
  fwtool info <file>
  fwtool unpack <file> -o <dir>
  fwtool strings <file> [-min N]
  fwtool compare <a> <b>

Run 'fwtool <subcommand> -h' for subcommand-specific help.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	sub := os.Args[1]
	args := os.Args[2:]
	// Allow flags to appear before or after positional arguments by
	// hoisting any "-x value" pairs we find scattered through args up to
	// the front. Stdlib flag.NewFlagSet is strict about ordering otherwise.
	args = reorderArgs(args)
	if err := dispatch(sub, args); err != nil {
		fmt.Fprintf(os.Stderr, "fwtool %s: %v\n", sub, err)
		os.Exit(1)
	}
}

// reorderArgs moves every "-flag value" (or "-flag=value") pair to the
// front of args, preserving relative order. Non-flag tokens keep their
// original ordering. This lets callers write either:
//
//	fwtool unpack <file> -o out
//	fwtool unpack -o out <file>
//
// the way most CLIs do.
func reorderArgs(args []string) []string {
	var flags, positional []string
	i := 0
	for i < len(args) {
		a := args[i]
		if strings.HasPrefix(a, "-") && a != "-" && a != "--" {
			flags = append(flags, a)
			// Peek: if next token is a value (doesn't start with "-"),
			// consume it as the flag's value.
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") &&
				!strings.Contains(a, "=") {
				flags = append(flags, args[i+1])
				i += 2
				continue
			}
			i++
			continue
		}
		positional = append(positional, a)
		i++
	}
	return append(flags, positional...)
}

func dispatch(sub string, args []string) error {
	switch sub {
	case "info":
		return cmdInfo(args)
	case "unpack":
		return cmdUnpack(args)
	case "strings":
		return cmdStrings(args)
	case "compare":
		return cmdCompare(args)
	case "-h", "--help", "help":
		fmt.Print(usage)
		return nil
	default:
		return fmt.Errorf("unknown subcommand %q", sub)
	}
}

// --- info ---------------------------------------------------------------

func cmdInfo(args []string) error {
	fs := flag.NewFlagSet("info", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	jsonOut := fs.Bool("json", false, "emit machine-parseable JSON instead of text")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("info requires exactly one <file>")
	}
	path := fs.Arg(0)
	f, err := format.ParseFile(path)
	if err != nil {
		return err
	}
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(f)
	}
	printInfo(os.Stdout, f)
	return nil
}

func printInfo(w io.Writer, f *format.File) {
	fmt.Fprintf(w, "file:        %s\n", f.Filename)
	fmt.Fprintf(w, "magic:       %s\n", f.Magic)
	fmt.Fprintf(w, "size:        %d bytes\n", f.Size)
	fmt.Fprintf(w, "sha256:      %s\n", f.SHA256)
	fmt.Fprintf(w, "hw_id:       %s\n", f.HWID)
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Header fields:")
	for _, fld := range f.Header.Fields {
		line := fmt.Sprintf("  0x%04X  %-18s = %v", fld.Offset, fld.Name, fld.Value)
		if fld.Note != "" {
			line += "  ; " + fld.Note
		}
		fmt.Fprintln(w, line)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Sections:")
	for _, s := range f.Sections {
		fmt.Fprintf(w, "  0x%06X..0x%06X  %-22s kind=%s", s.Offset, s.Offset+s.Size, s.Name, s.Kind)
		if s.Format != "" {
			fmt.Fprintf(w, " format=%s", s.Format)
		}
		if s.Note != "" {
			fmt.Fprintf(w, "  ; %s", s.Note)
		}
		fmt.Fprintln(w)
	}
	if len(f.Notes) > 0 {
		fmt.Fprintln(w)
		fmt.Fprintln(w, "Notes:")
		for _, n := range f.Notes {
			fmt.Fprintf(w, "  - %s\n", n)
		}
	}
}

// --- unpack -------------------------------------------------------------

func cmdUnpack(args []string) error {
	fs := flag.NewFlagSet("unpack", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	outDir := fs.String("o", "", "output directory (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("unpack requires exactly one <file>")
	}
	if *outDir == "" {
		return errors.New("unpack requires -o <dir>")
	}
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return fmt.Errorf("mkdir -p %s: %w", *outDir, err)
	}

	path := fs.Arg(0)
	f, err := format.ParseFile(path)
	if err != nil {
		return err
	}
	buf, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	// header.json
	headerJSON, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*outDir, "header.json"), headerJSON, 0o644); err != nil {
		return err
	}

	// strings.txt
	ss := format.ScanStrings(buf, 4)
	var sb strings.Builder
	for _, e := range ss {
		fmt.Fprintf(&sb, "0x%08X  %-7s  %s\n", e.Offset, e.Kind, e.Text)
	}
	if err := os.WriteFile(filepath.Join(*outDir, "strings.txt"), []byte(sb.String()), 0o644); err != nil {
		return err
	}

	// embedded assets
	for _, s := range f.Sections {
		if s.Kind != "embedded-asset" {
			continue
		}
		end := s.Offset + s.Size
		if end > int64(len(buf)) {
			end = int64(len(buf))
		}
		out := filepath.Join(*outDir, "assets", s.Name)
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(out, buf[s.Offset:end], 0o644); err != nil {
			return err
		}
	}

	// raw body (everything past the parsed header) — useful for further RE.
	body := buf[format.MinSize-16:] // include last 16 bytes of header for context
	if int64(len(body)) > f.Size-format.MinSize+16 {
		body = buf[f.Size-format.MinSize+16:]
	}
	if err := os.WriteFile(filepath.Join(*outDir, "body.bin"), body, 0o644); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "wrote %d files into %s\n",
		countDir(*outDir), *outDir)
	return nil
}

func countDir(dir string) int {
	n := 0
	_ = filepath.Walk(dir, func(_ string, _ os.FileInfo, _ error) error {
		n++
		return nil
	})
	return n
}

// --- strings ------------------------------------------------------------

func cmdStrings(args []string) error {
	fs := flag.NewFlagSet("strings", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	min := fs.Int("min", 4, "minimum length")
	jsonOut := fs.Bool("json", false, "emit machine-parseable JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("strings requires exactly one <file>")
	}
	buf, err := os.ReadFile(fs.Arg(0))
	if err != nil {
		return err
	}
	ss := format.ScanStrings(buf, *min)
	sort.SliceStable(ss, func(i, j int) bool {
		if ss[i].Offset != ss[j].Offset {
			return ss[i].Offset < ss[j].Offset
		}
		return ss[i].Kind < ss[j].Kind
	})
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(ss)
	}
	for _, e := range ss {
		fmt.Printf("0x%08X  %-7s  %s\n", e.Offset, e.Kind, e.Text)
	}
	return nil
}

// --- compare ------------------------------------------------------------

func cmdCompare(args []string) error {
	fs := flag.NewFlagSet("compare", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	jsonOut := fs.Bool("json", false, "emit machine-parseable JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return errors.New("compare requires <a> <b>")
	}
	a, err := loadRaw(fs.Arg(0))
	if err != nil {
		return err
	}
	b, err := loadRaw(fs.Arg(1))
	if err != nil {
		return err
	}
	shaA := sha256Hex(a)
	shaB := sha256Hex(b)
	res := format.Compare(a, b, fs.Arg(0), fs.Arg(1), shaA, shaB)
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(res)
	}
	fmt.Printf("A: %s  size=%d  sha256=%s\n", res.A, res.SizeA, shaA)
	fmt.Printf("B: %s  size=%d  sha256=%s\n", res.B, res.SizeB, shaB)
	fmt.Printf("same_sha256=%v  identical=%d  divergent=%d\n",
		res.SameSHA, res.IdenticalBytes, res.DivergentBytes)
	fmt.Println("Regions:")
	for _, r := range res.Regions {
		fmt.Printf("  0x%06X..0x%06X  %-9s  size=%d\n",
			r.Offset, r.Offset+r.Size, r.Status, r.Size)
	}
	return nil
}

func loadRaw(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func sha256Hex(b []byte) string {
	// local import would be a cycle (format imports crypto/sha256); do it inline.
	// We re-use format's hashing by parsing — but that errors on tiny files,
	// so we keep a tiny wrapper here.
	return sha256HexInline(b)
}