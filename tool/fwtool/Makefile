GO ?= go
BIN ?= fwtool
PKG ?= ./...

.PHONY: build test vet fmt clean run-info run-unpack run-strings run-compare

build:
	$(GO) build -o $(BIN) ./cmd/fwtool

test:
	$(GO) test $(PKG)

test-v:
	$(GO) test -v $(PKG)

vet:
	$(GO) vet $(PKG)

fmt:
	$(GO) fmt $(PKG)

clean:
	rm -f $(BIN)

run-info: build
	./$(BIN) info ../../firmwares/H59MA_1.00.13_251230.bin

run-unpack: build
	./$(BIN) unpack ../../firmwares/H59MA_1.00.13_251230.bin -o out_v13

run-strings: build
	./$(BIN) strings ../../firmwares/H59MA_1.00.13_251230.bin | head -40

run-compare: build
	./$(BIN) compare ../../firmwares/H59MA_1.00.13_251230.bin ../../firmwares/H59MA_1.00.14_260508.bin | head -40