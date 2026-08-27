---
name: "libgit2 misses Apple git's system config"
description: "Apple's git reads its system config from the developer directory, and libgit2 only reaches it as a last-resort fallback"
type: reference
---

# libgit2 misses Apple git's system config

Apple compiles `/usr/bin/git` to read its **system** configuration from the
active developer directory —
`/Applications/Xcode.app/Contents/Developer/usr/share/git-core/gitconfig`, or
the Command Line Tools' equivalent. libgit2 searches `/etc` and a package
manager's prefix instead, so the two disagree about every system-level setting
a macOS user has. Two of them matter to Casper: `init.defaultBranch` (`git
init` lands on `main` while a bare `git_repository_init` lands on `master`) and
`user.name` / `user.email`, which decide whether `git_signature_default`
resolves an identity at all.

`Libgit2.ensureInit()` narrows the gap once per process, before any repository
is opened: it reads libgit2's system-level config search path
(`GIT_OPT_GET_SEARCH_PATH`), appends the developer-directory `git-core`
directories that exist on disk, and writes the result back
(`GIT_OPT_SET_SEARCH_PATH`).

## A fallback, not a merge

libgit2 resolves a config **level** to the **first existing file** along that
level's search path — it does not merge every directory the path names. With
the path `A:B` and a `gitconfig` in both, `git_config_find_system` answers
`A/gitconfig`; with `B:A` it answers `B/gitconfig`.

So appending puts Apple's directory *behind* everything libgit2 already
searches, and it is read only when no earlier directory holds a `gitconfig`.
On the common macOS setup — the default system search path is `/etc`, and macOS
ships no `/etc/gitconfig` — Apple's file becomes the system config, and
`git_repository_init` moves from `refs/heads/master` onto whatever
`init.defaultBranch` says. Where `/etc/gitconfig` or a package manager's
prefixed `gitconfig` **does** exist, that file is read **instead of** Apple's
and the augmentation changes nothing.

The append order is the deliberate half of the trade: prepending would let
Apple's file shadow a system config an administrator installed on purpose,
which is a worse failure than being inert.

`GIT_OPT_SET_SEARCH_PATH` also governs libgit2's **shared attributes and ignore
files**, so an appended directory can supply a `gitattributes` as well — Apple's
`git-core` ships one (`*.m diff=objc`, `*.mm diff=objc`, `*.swift
diff=swift`). It selects diff drivers, which Casper's diff rendering does not
consult: the same file produces byte-identical deltas, flags and text lines with
and without the Apple directory on the path.

## Discovery and the tests

Discovery is `$DEVELOPER_DIR/usr/share/git-core`, then Xcode's standard
location, then the Command Line Tools' — keeping only what exists. Nothing is
asked of a subprocess: `xcode-select` is off limits for the reason `which` is
(see [[shell-path-resolution]]). An Xcode installed at a non-standard path with
no `DEVELOPER_DIR` in the environment is therefore not found, and libgit2 keeps
its own search path — a graceful fallback rather than a failure. Every step is
best-effort for the same reason: resolving configuration better must not give
initialization a new way to fail.

`Libgit2Tests` pins the search-path *string*. The user-visible effect is pinned
separately, by `testAFreshRepositoryIsBornOnTheSystemConfigDefaultBranch`: it
reads `init.defaultBranch` out of the resolved system `gitconfig` and asserts a
`Repository.initialize` lands on that branch, skipping when the resolved file is
not the Apple one — precisely the machines where the augmentation is inert.

`git_libgit2_opts` is **variadic**, so Swift cannot call it at all — the
ClangImporter rule that also rules out `git_commit_create_v`
([[libgit2-swift-interop]]). Two `static inline` wrappers in
`Sources/Clibgit2/shim.h` — `casper_git_get_config_search_path` and
`casper_git_set_config_search_path` — give Swift a callable entry point.

**How to apply:** a libgit2 answer that disagrees with what the user's own
`git` prints in the terminal is a config-resolution question first. Check where
`git config --show-origin <key>` finds the value, whether libgit2's search path
names that directory, and whether an earlier directory on that path already
answers the level.
