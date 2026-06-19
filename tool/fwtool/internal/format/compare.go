package format

// Region is a span of bytes that share the same identity verdict
// across two firmware images.
type Region struct {
	Offset int64 `json:"offset"`
	Size   int64 `json:"size"`
	Status string `json:"status"` // "identical" or "divergent"
}

// CompareResult summarises a side-by-side comparison.
type CompareResult struct {
	A        string   `json:"a"`
	B        string   `json:"b"`
	SizeA    int64    `json:"size_a"`
	SizeB    int64    `json:"size_b"`
	Regions  []Region `json:"regions"`
	SameSHA  bool     `json:"same_sha256"`
	IdenticalBytes int64 `json:"identical_bytes"`
	DivergentBytes int64 `json:"divergent_bytes"`
}

// Compare runs a deterministic byte-level diff between two already-loaded
// firmware buffers and returns a list of identical/divergent regions.
// shaA / shaB should be the hex SHA-256 of bufA / bufB respectively.
func Compare(bufA, bufB []byte, nameA, nameB, shaA, shaB string) CompareResult {
	minLen := len(bufA)
	if len(bufB) < minLen {
		minLen = len(bufB)
	}

	res := CompareResult{
		A:       nameA,
		B:       nameB,
		SizeA:   int64(len(bufA)),
		SizeB:   int64(len(bufB)),
		SameSHA: shaA == shaB,
	}

	const runMax int64 = 4096 // flush region after this many bytes either way
	var off int64
	var status string // "" | "same" | "diff"
	flush := func(end int64) {
		if status == "" {
			return
		}
		res.Regions = append(res.Regions, Region{
			Offset: off,
			Size:   end - off,
			Status: statusLabel(status),
		})
		if status == "same" {
			res.IdenticalBytes += end - off
		} else {
			res.DivergentBytes += end - off
		}
		off = end
		status = ""
	}

	for i := 0; i < minLen; i++ {
		same := bufA[i] == bufB[i]
		cur := "diff"
		if same {
			cur = "same"
		}
		if cur != status {
			flush(int64(i))
			status = cur
		}
		if int64(i)-off >= runMax {
			flush(int64(i) + 1)
		}
	}
	flush(int64(minLen))

	// Tail region if sizes differ.
	if int64(len(bufA)) > int64(minLen) {
		res.Regions = append(res.Regions, Region{
			Offset: int64(minLen),
			Size:   int64(len(bufA)) - int64(minLen),
			Status: "divergent",
		})
		res.DivergentBytes += int64(len(bufA)) - int64(minLen)
	} else if int64(len(bufB)) > int64(minLen) {
		res.Regions = append(res.Regions, Region{
			Offset: int64(minLen),
			Size:   int64(len(bufB)) - int64(minLen),
			Status: "divergent",
		})
		res.DivergentBytes += int64(len(bufB)) - int64(minLen)
	}

	return res
}

func statusLabel(s string) string {
	if s == "same" {
		return "identical"
	}
	return "divergent"
}