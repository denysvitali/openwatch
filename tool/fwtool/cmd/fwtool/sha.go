package main

import (
	"crypto/sha256"
	"encoding/hex"
)

func sha256HexInline(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}