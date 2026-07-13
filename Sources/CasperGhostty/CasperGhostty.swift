import GhosttyKit

/// CasperGhostty is the *only* module that touches the unstable libghostty
/// embedding API. Everything `ghostty_*` is confined here (see the design's
/// hard constraint on API isolation). A libghostty version bump touches only
/// this target.
///
/// Pinned to Ghostty `v1.3.1` via the `Lakr233/libghostty-spm` `1.2.8` binary
/// package. See `Vendor/ghostty/ghostty.h` for the exact API this code is written
/// against.
public enum CasperGhostty {
    /// The upstream Ghostty tag the linked GhosttyKit was built from.
    public static let pinnedGhosttyVersion = "v1.3.1"
}

/// A libghostty embedding failure, surfaced instead of crashing (mirrors the
/// never-crash error pattern of `CasperGit.GitError`). Carries a human-readable
/// reason.
struct GhosttyError: Error, Equatable, Sendable {
    let reason: String
}
