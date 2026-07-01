# Casper — developer tasks
# Requires the Xcode toolchain selected (sudo xcode-select -s /Applications/Xcode.app)
# so that `swift test` can link XCTest.

.DEFAULT_GOAL := build
.PHONY: all build test release clean help

## build: compile the debug build
build:
	swift build

## test: run the full test suite
test:
	swift test

## all: build then test
all: build test

## release: size-optimized release build (arm64)
release:
	swift build -c release

## clean: remove build artifacts
clean:
	rm -rf .build

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
