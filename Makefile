# Casper — developer tasks
# Requires the Xcode toolchain selected (sudo xcode-select -s /Applications/Xcode.app)
# so that `swift test` can link XCTest, and libgit2 + pkgconf installed
# (brew install libgit2 pkgconf) so that CasperGit can link libgit2.

.DEFAULT_GOAL := build
.PHONY: all build dev test release clean vendor help bundle dist

# Version metadata for packaging (overridable by CI). SHORT_VERSION is the
# marketing version; BUNDLE_VERSION is a monotonic build number.
SHORT_VERSION ?= $(shell v=$$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'); echo $${v:-0.0.0})
BUNDLE_VERSION ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

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

## bundle: assemble a self-contained Casper.app (release binary + bundled dylibs)
bundle: release
	Scripts/bundle-app.sh $(SHORT_VERSION) $(BUNDLE_VERSION)

## dist: package Casper.app into a downloadable release archive + checksum
dist: bundle
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent Casper.app dist/Casper-$(SHORT_VERSION)-arm64.zip
	cd dist && shasum -a 256 Casper-$(SHORT_VERSION)-arm64.zip > Casper-$(SHORT_VERSION)-arm64.zip.sha256

## clean: remove build artifacts
clean:
	rm -rf .build

## vendor: re-sync vendored files (pinned libghostty header) via Carvel vendir
vendor:
	vendir sync

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
