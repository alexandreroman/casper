---
name: libgit2-swift-interop
description: libgit2 C-API gotchas when calling it from Swift in CasperGit (Clibgit2)
type: reference
---

Gotchas hit while building `CasperGit` (the `Clibgit2` systemLibrary wrapper over
libgit2 1.9.x). Relevant to any future CasperGit work (e.g. adding `git_diff`).

- **Variadic `_v` functions are NOT importable by Swift.** Use the array-based
  variant instead. Concretely: `git_commit_create_v(...)` cannot be called from
  Swift — use `git_commit_create(&oid, repo, "HEAD", author, committer, nil,
  msg, tree, parentCount, parents)` (pass `0, nil` for a root commit). Assume the
  same for any other `*_v` libgit2 API.
- **Linking:** `Clibgit2` is a `.systemLibrary(pkgConfig: "libgit2",
  providers: [.brew(["libgit2"])])` with a `module.modulemap` (`link "git2"`) and
  a `shim.h` that `#include <git2.h>`. Dynamic link against Homebrew's libgit2;
  build host needs `brew install libgit2 pkgconf`.
- **Error codes** (`GIT_ENOTFOUND`, etc.) import as enum values — compare with
  `code == GIT_ENOTFOUND.rawValue`. Options-struct version macros
  (`GIT_*_OPTIONS_VERSION`) and flag enums (`GIT_STATUS_OPT_*`,
  `GIT_WORKTREE_PRUNE_*`) are used via `UInt32(...)` / `.rawValue`.
- **Pointer lifecycle:** wrapper types owning a `git_*` handle are `final class`
  with `deinit { git_*_free }`; for locals, place `defer { free/dispose }`
  BEFORE the fallible call so the throw path also frees (this bit us once in
  `gitStringArray`). `git_buf` → `git_buf_dispose`; `git_strarray` →
  `git_strarray_dispose`.
- **Test fixtures build real repos via libgit2 only** (no `git` binary, per
  dependency policy). CasperGit's internal `gitCheck` is not visible from
  `CasperCoreTests`, so that target's commit helper uses a local check instead.

See [[dependency-policy]], [[test-toolchain]].
