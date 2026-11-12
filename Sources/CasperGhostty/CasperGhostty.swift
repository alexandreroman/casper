// CasperGhostty is the *only* module that touches the unstable libghostty
// embedding API. Everything `ghostty_*` is confined here (see the design's
// hard constraint on API isolation). A libghostty version bump touches only
// this target.
//
// Pinned by revision to the `Lakr233/libghostty-spm` binary package (see
// `Package.swift`). See `Vendor/ghostty/ghostty.h` for the exact API this code is
// written against.

/// A libghostty embedding failure, surfaced instead of crashing (mirrors the
/// never-crash error pattern of `CasperGit.GitError`). Carries a human-readable
/// reason.
struct GhosttyError: Error {
    let reason: String
}
