# Casper — developer tasks
# Requires the Xcode toolchain selected (sudo xcode-select -s /Applications/Xcode.app)
# so that `swift test` can link XCTest, and libgit2 + pkgconf installed
# (brew install libgit2 pkgconf) so that CasperGit can link libgit2.

.DEFAULT_GOAL := build
.PHONY: all build dev test release clean vendor help

## build: compile the debug build
build:
	swift build

## dev: recompile and launch the app
dev:
	swift run casper

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

## vendor: re-sync vendored files (pinned libghostty header) via Carvel vendir
vendor:
	vendir sync

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
