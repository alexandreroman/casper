import Foundation

// Pure, testable agent-state detection engine.
//
// This file owns only the *policy*: turning what a terminal reports — viewport
// text, the OSC title, and the OSC 9;4 progress state — into a raw signal,
// rolling several surfaces' signals up to one workspace signal, and debouncing
// that signal into a reported `AgentState`. It performs no I/O and reads no
// real terminals — the caller supplies the viewport text and the "seen" flag.
// Keeping it side-effect-free makes the whole thing unit-testable and keeps
// every Ghostty/UI concern out of CasperCore (see
// `.superpowers/themes/agent-state-detection.md`).

/// A raw, per-tick observation about what an agent surface is doing.
///
/// `absent` means there is no live/readable agent (the matcher never produces
/// it — only the caller does, when no agent surface exists).
public enum AgentSignal: String, Equatable, Sendable {
    case working, blocked, idle, absent
}

/// Ordered by urgency, `absent < idle < working < blocked`, so rolling several
/// surfaces' signals up to the most urgent one is just a `max`.
extension AgentSignal: Comparable {
    public static func < (lhs: AgentSignal, rhs: AgentSignal) -> Bool {
        lhs.urgency < rhs.urgency
    }

    /// Higher wins during aggregation.
    private var urgency: Int {
        switch self {
        case .blocked: return 3
        case .working: return 2
        case .idle: return 1
        case .absent: return 0
        }
    }
}

/// The terminal's OSC 9;4 (ConEmu/iTerm2) progress-report state.
///
/// Mirrors libghostty's `ghostty_action_progress_report_state_e` one-for-one
/// (`GHOSTTY_PROGRESS_STATE_REMOVE`, `_SET`, `_ERROR`, `_INDETERMINATE`,
/// `_PAUSE`), restated here so that C enum never leaks into CasperCore, which
/// must not depend on GhosttyKit. The translation lives in CasperGhostty.
public enum AgentProgressState: String, Equatable, Sendable {
    case removed, set, error, indeterminate, paused
}

extension AgentSignal {
    /// Rolls several surfaces' signals up to the single most urgent one. An empty
    /// input (no surfaces observed) is `absent`. Callers combining a fixed pair of
    /// signals can use `max(_:_:)` directly instead.
    public static func aggregate(_ signals: [AgentSignal]) -> AgentSignal {
        signals.max() ?? .absent
    }

    /// Reads a terminal progress report as a raw signal.
    ///
    /// `set`/`indeterminate` are what make this the *primary* `working` signal:
    /// Claude Code emits `ESC]9;4;3` (indeterminate) for the whole duration of a
    /// turn and `ESC]9;4;0` when it ends — verified against a real Claude Code
    /// 2.1.239 PTY capture.
    ///
    /// The other three are `absent`, each for its own reason:
    ///
    /// - `removed` means "this source has nothing to say", deliberately not
    ///   `idle`: reading it as `idle` would make a plain shell that never reports
    ///   progress indistinguishable from an agent that just finished, and would
    ///   let a silent source outvote nothing.
    /// - `error` records the *outcome* of finished work, not liveness, and the bar
    ///   lingers on screen until the next report — pinning the workspace to a
    ///   state on it would be a guess.
    /// - `paused` is emitted by no agent Casper targets, and a suspended bar
    ///   asserts neither liveness nor rest.
    public init(progress: AgentProgressState) {
        switch progress {
        case .set, .indeterminate: self = .working
        case .removed, .error, .paused: self = .absent
        }
    }
}

/// A data-driven matcher describing an agent's on-screen affordances. Patterns
/// live in the value (not hard-coded control flow) so a new agent is just a new
/// `AgentDetectionRuleSet`.
public struct AgentDetectionRuleSet: Equatable, Sendable {
    /// Any single substring present ⇒ `working`.
    private let workingContains: [String]
    /// Any group whose every substring is present ⇒ `blocked`.
    private let blockedAllOf: [[String]]
    /// Unicode scalar ranges whose prefix in the OSC title ⇒ `working`. Several
    /// disjoint ranges rather than one widened range: Claude Code 2.1.239 spins
    /// the quadrant circles ◐◑◒◓ (U+25D0–U+25D3) while earlier builds spun Braille
    /// (U+2800–U+28FF), and bridging the gap between the two would swallow every
    /// unrelated symbol in between. An empty list disables title-`working`
    /// matching outright.
    private let titleWorkingScalars: [ClosedRange<UInt32>]
    /// Single Unicode scalar whose prefix in the OSC title ⇒ `idle`.
    private let titleIdleScalar: UInt32?

    public init(
        workingContains: [String],
        blockedAllOf: [[String]],
        titleWorkingScalars: [ClosedRange<UInt32>] = [0x2800...0x28FF, 0x25D0...0x25D3],
        titleIdleScalar: UInt32? = 0x2733
    ) {
        self.workingContains = workingContains
        self.blockedAllOf = blockedAllOf
        self.titleWorkingScalars = titleWorkingScalars
        self.titleIdleScalar = titleIdleScalar
    }

    /// Classifies a viewport snapshot. Matching is case-insensitive and,
    /// critically, `blocked` is checked before `working`: a confirmation prompt
    /// can coexist on screen with a stale interrupt hint, and the pending
    /// question is what actually needs the user. Never returns `.absent` — the
    /// caller supplies that when no agent is present.
    public func signal(fromViewport text: String) -> AgentSignal {
        // Match the fixed lowercase-ASCII needles case-insensitively against the
        // raw text: this avoids allocating a full lowercased copy of the viewport
        // on every tick per surface, yet yields the same matches as before.
        if blockedAllOf.contains(where: { text.containsAll($0) }) {
            return .blocked
        }
        let isWorking = workingContains.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        return isWorking ? .working : .idle
    }

    /// Classifies the terminal's OSC title. Claude Code still encodes its live
    /// state there, but the spinner glyph moved: 2.1.239 prints the quadrant
    /// circles ◐◑◒◓ (U+25D0–U+25D3) while working — verified from a real PTY
    /// capture (`ESC]0;◐ Claude Code`) — where earlier builds printed Braille
    /// (U+2800–U+28FF); both prefixes match, and the ✳ (U+2733) at-rest prefix is
    /// unchanged. Because the glyph set is not stable across releases, the title
    /// is a *secondary* signal behind the OSC 9;4 progress report. The shell also
    /// sets the title (to the running command or cwd) between agent runs; such
    /// titles have neither prefix and yield `.absent`, so they never produce a
    /// false `working`.
    public func signal(fromTitle title: String) -> AgentSignal {
        guard let first = title.unicodeScalars.first(where: { $0 != " " }) else { return .absent }
        if titleWorkingScalars.contains(where: { $0.contains(first.value) }) { return .working }
        if first.value == titleIdleScalar { return .idle }
        return .absent
    }

    /// Claude Code's on-screen affordances. Substrings are lowercase ASCII and are
    /// matched case-insensitively against the raw viewport text (no lowercased copy
    /// is allocated). The OSC-title convention (a spinner prefix — quadrant circles
    /// U+25D0–U+25D3 or Braille U+2800–U+28FF — = working, ✳ U+2733 = idle) comes
    /// from the initializer's defaults.
    public static let claudeCode = AgentDetectionRuleSet(
        workingContains: [
            "esc to interrupt",
            "ctrl+c to interrupt",
        ],
        blockedAllOf: [
            ["do you want to proceed?", "esc to cancel"],
        ])

    /// Codex exposes its live state in the terminal viewport rather than a
    /// documented OSC-title convention. Its interrupt affordance is rendered
    /// only while a turn is executing, so it is a native, terminal-owned signal
    /// that can recover a stale hook-reported `.working` state. Keep title
    /// matching disabled here: a Codex shell title is not an execution signal.
    public static let codex = AgentDetectionRuleSet(
        workingContains: [
            "esc to interrupt",
            "ctrl+c to interrupt",
            "running tools",
        ],
        blockedAllOf: [
            ["do you want to proceed?", "esc to cancel"],
        ],
        titleWorkingScalars: [],
        titleIdleScalar: nil)

    /// opencode's on-screen affordances, measured against opencode 1.18.20 running
    /// under a Casper-like terminal (`TERM_PROGRAM=ghostty`,
    /// `TERM_PROGRAM_VERSION=1.3.1`). It emits **no** OSC 9;4 progress report at
    /// all, and its OSC title is plain ASCII (`OpenCode`, `OC | <turn title>`) with
    /// no glyph convention — so title matching stays disabled and the viewport is
    /// its only source. While a turn runs, the footer row offers `esc interrupt`
    /// (no "to", so Claude Code's needles do not match it), and the at-rest footer
    /// overwrites that row as soon as the turn ends, so the affordance does not
    /// latch. A pending permission prompt renders `Permission required` above
    /// `Allow once` / `Reject` *while the interrupt footer is still on screen*,
    /// which is exactly why `signal(fromViewport:)` tests `blocked` first. Both
    /// needles are required so a chat message quoting either phrase on its own
    /// cannot trip it.
    public static let opencode = AgentDetectionRuleSet(
        workingContains: [
            "esc interrupt",
        ],
        blockedAllOf: [
            ["permission required", "allow once"],
        ],
        titleWorkingScalars: [],
        titleIdleScalar: nil)

    /// Every known rule set, evaluated together on each detection pass.
    ///
    /// Casper owns the PTY but has no way to know *which* agent occupies a given
    /// surface, so rather than pick one rule set it applies them all to the same
    /// snapshot and aggregates the signals (`AgentSignal.aggregate`), letting the
    /// most urgent one win. Each rule set's needles are specific enough to stay
    /// quiet on another agent's screen, and the union is what makes the Codex and
    /// opencode rules reachable at runtime at all.
    public static let all: [AgentDetectionRuleSet] = [.claudeCode, .codex, .opencode]
}

extension String {
    /// True when every needle appears in the string, matched case-insensitively so
    /// callers can test raw viewport text without allocating a lowercased copy.
    fileprivate func containsAll(_ needles: [String]) -> Bool {
        needles.allSatisfy { range(of: $0, options: .caseInsensitive) != nil }
    }
}

/// Turns a stream of raw workspace signals into the reported `AgentState`.
///
/// The only piece that carries state across ticks. It debounces the
/// `working → idle` transition (a gap between two tool calls must not flicker to
/// idle) and derives `done`: a completion the user has not yet seen. Feed it one
/// aggregated signal per tick; it is a value type, so callers own a copy per
/// workspace.
public struct AgentStateResolver: Sendable {
    /// Whether a `working` signal has been seen since the last completion/reset.
    /// Distinguishes a real `working → idle` completion (which can become
    /// `done`) from a workspace that was idle from the start.
    private var observedWorking = false
    /// Consecutive idle ticks accumulated since work stopped, compared against
    /// the debounce threshold before a completion is accepted.
    private var idleStreak = 0
    /// Latches once a completion is reported unseen, so `done` persists across
    /// ticks until the workspace is finally seen.
    private var doneLatched = false

    public init() {}

    /// Resolves this tick's raw `signal` into the state to report.
    ///
    /// - Parameters:
    ///   - signal: the workspace's aggregated raw signal for this tick.
    ///   - seen: whether the workspace is currently focused/selected.
    ///   - debounce: consecutive idle ticks required before a `working → idle`
    ///     completion is accepted (so a brief pause mid-run is not mistaken for
    ///     completion).
    public mutating func resolve(signal: AgentSignal, seen: Bool, debounce: Int = 2) -> AgentState {
        switch signal {
        case .working:
            // A live run clears any pending completion and the done latch.
            observedWorking = true
            idleStreak = 0
            doneLatched = false
            return .working

        case .blocked:
            idleStreak = 0
            doneLatched = false
            return .blocked

        case .absent:
            // No readable agent: nothing to debounce or attend to.
            observedWorking = false
            idleStreak = 0
            doneLatched = false
            return .unknown

        case .idle:
            return resolveIdle(seen: seen, debounce: debounce)
        }
    }

    private mutating func resolveIdle(seen: Bool, debounce: Int) -> AgentState {
        // A completion already reported unseen holds as `done` until seen.
        if doneLatched {
            guard seen else { return .done }
            doneLatched = false
            return .idle
        }

        // Never worked ⇒ plainly idle, no debounce, never `done`.
        guard observedWorking else { return .idle }

        idleStreak += 1
        if idleStreak < debounce {
            // Transition not yet accepted: keep reporting the prior working run.
            return .working
        }

        // `working → idle` completion accepted; reset for the next run.
        idleStreak = 0
        observedWorking = false
        if seen {
            return .idle
        }
        // Completed while the user was looking elsewhere ⇒ attention state.
        doneLatched = true
        return .done
    }
}
