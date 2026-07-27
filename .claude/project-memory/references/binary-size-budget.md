---
name: "Release binary size budget"
description: "Measured size levers on the shipped binary, which ones are applied, and which are deliberately left on the table"
type: project
---

# Release binary size budget

The size levers below are measured on this codebase (arm64, macOS 15 target),
not estimated. `CLAUDE.md` documents the resulting pipeline; this note records
the numbers and the trade-offs behind it.

**Applied:**

- `strip -x` on the bundled executable — **−3.76 MB** (13.07 → 9.31 MB). By far
  the largest lever, and the reason `Scripts/bundle-app.sh` extracts a dSYM
  first.
- `-Osize` — **−0.31 MB** (`__text` 4.52 → 4.18 MB).

**Deliberately absent:**

- `-dead_strip` belongs to no target: it was measured at **exactly zero bytes**
  on this binary. Adding it buys link time and nothing else.
- The bundle embeds the universal (x86_64 + arm64) Sparkle framework as
  shipped. Thinning it to arm64 is worth **−1.2 MB**, but Apple's signature on
  the framework seals the nested `Autoupdate`, `Updater.app` and the two XPC
  services that Sparkle launches during an install, so thinning forces an ad-hoc
  re-signature of all of them — a failure mode that only surfaces months later,
  at the last step of a real update.
- libgit2 comes from Homebrew, which builds it with SSH and OpenSSL, so
  `libcrypto` (4.6 MB), `libssl` (0.87 MB) and `libssh2` (0.28 MB) ride along in
  `Contents/Frameworks`. `CasperGit` never reaches the network — its only remote
  call is `git_remote_url`, a config read — so those **5.75 MB are dead weight**
  and represent the single largest remaining lever. Reclaiming them means a
  pinned source build (`cmake -DUSE_SSH=OFF -DUSE_HTTPS=OFF
  -DUSE_SHA256=CommonCrypto -DUSE_HTTP_PARSER=builtin -DBUILD_SHARED_LIBS=OFF`,
  verified to configure and link cleanly), which trades the `libgit2` Homebrew
  dependency for a `cmake` one in every dev and CI environment.

**Why:** the number users feel is the **zip**, not the bundle, and symbols
compress well — the applied levers move `Casper.app` from 25 → 21 MB on disk but
the download only from 10.93 → 10.26 MB. Weigh any further lever against the
zip, and against the risk it adds to the update path.

**How to apply:** measure with `ls -l` on the bundled executable, `du -sh` on
`Casper.app` **and** the `dist/*.zip`, never on `.build/release/casper` alone.
The dSYM stays out of `Casper.app` and out of the appcast enclosure — the
enclosure in `.github/workflows/release.yml` covers `Casper-<v>-arm64.zip` only,
so Sparkle never pulls debug symbols on an update. Its UUID must match the
shipped binary, which is why `dsymutil` runs inside `bundle-app.sh` rather than
as a separate step. See [[hang-dump-watchdog]] for what the published dSYM does
and does not cover.
