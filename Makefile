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

# Per-branch dev session name: sanitize the current branch to SessionIdentity's
# charset ([A-Za-z0-9._-], max 32 chars) so two worktrees on different branches
# get independent, non-colliding dev sessions. Falls back to "dev".
DEV_SESSION := $(shell br=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null); \
	name=$$(printf '%s' "$$br" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-32); \
	echo "$${name:-dev}")

# Local code-signing identity for debug builds (Screen Recording TCC
# persistence — see .superpowers/plans/screenshot-capture-permissions.md).
# Auto-detects the first "Apple Development" identity in the keychain;
# override with `make build CODESIGN_IDENTITY="Apple Development: ..."`.
# Empty means "no identity available" — falls back to an ad-hoc signature.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -m1 'Apple Development' | sed -E 's/.*"(Apple Development[^"]*)".*/\1/')
DEV_BUNDLE_ID := com.github.alexandreroman.casper.dev
DEV_APP := Casper-dev.app

## build: compile the debug build and assemble the signed dev app bundle
build:
	swift build
	@rm -rf $(DEV_APP)
	@mkdir -p $(DEV_APP)/Contents/MacOS $(DEV_APP)/Contents/Resources
	@cp .build/debug/casper $(DEV_APP)/Contents/MacOS/casper
	@cp Packaging/Sounds/NotificationAlert.aiff $(DEV_APP)/Contents/Resources/NotificationAlert.aiff
	@sed -e "s/__DEV_BUNDLE_ID__/$(DEV_BUNDLE_ID)/g" \
		Packaging/Info-dev.plist > $(DEV_APP)/Contents/Info.plist
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(DEV_APP); \
	else \
		codesign --force --sign - $(DEV_APP); \
		echo "note: no Apple Development signing identity found — $(DEV_APP)" \
			"stays ad-hoc signed and Screen Recording permission will" \
			"reset on rebuild. Setup: .superpowers/plans/screenshot-capture-permissions.md"; \
	fi

## dev: recompile and launch the app under a per-branch isolated dev session
dev: build
	@echo "==> dev session: $(DEV_SESSION)"
	$(DEV_APP)/Contents/MacOS/casper --session $(DEV_SESSION)

## test: run the full test suite
# Strip the ambient CASPER_* socket/session vars: running tests inside a terminal
# that Casper itself opened would otherwise leak that instance's real control/debug
# socket paths into the test process, masking tests that assert env-independent
# path derivation.
test:
	env -u CASPER_CONTROL_SOCKET -u CASPER_DEBUG_SOCKET -u CASPER_SESSION swift test

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
	rm -rf .build $(DEV_APP)

## vendor: re-sync vendored files (pinned libghostty header) via Carvel vendir
vendor:
	vendir sync

## help: list available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'
