// Pure, testable agent-state detection engine.
//
// This file owns only the *policy*: turning terminal viewport text into a raw
// signal, rolling several surfaces' signals up to one workspace signal, and
// debouncing that signal into a reported `AgentState`. It performs no I/O and
// reads no real terminals — the caller supplies the viewport text and the
// "seen" flag. Keeping it side-effect-free makes the whole thing unit-testable
// and keeps every Ghostty/UI concern out of CasperCore (see
// `.superpowers/themes/agent-state-detection.md`).

/// A raw, per-tick observation about what an agent surface is doing.
///
/// `absent` means there is no live/readable agent (the matcher never produces
/// it — only the caller does, when no agent surface exists).
public enum AgentSignal: String, Equatable, Sendable {
    case working, blocked, idle, absent
}

extension AgentSignal {
    /// Rolls several surfaces' signals up to the single most urgent one, using
    /// the priority `blocked > working > idle > absent`. An empty input (no
    /// surfaces observed) is `absent`.
    public static func aggregate(_ signals: [AgentSignal]) -> AgentSignal {
        signals.max(by: { $0.urgency < $1.urgency }) ?? .absent
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

/// A data-driven matcher describing an agent's on-screen affordances. Patterns
/// live in the value (not hard-coded control flow) so a new agent is just a new
/// `AgentDetectionRuleSet`.
public struct AgentDetectionRuleSet: Equatable, Sendable {
    /// Any single substring present ⇒ `working`.
    public var workingContains: [String]
    /// Any group whose every substring is present ⇒ `working`.
    public var workingAllOf: [[String]]
    /// Any group whose every substring is present ⇒ `blocked`.
    public var blockedAllOf: [[String]]

    public init(workingContains: [String], workingAllOf: [[String]], blockedAllOf: [[String]]) {
        self.workingContains = workingContains
        self.workingAllOf = workingAllOf
        self.blockedAllOf = blockedAllOf
    }

    /// Classifies a viewport snapshot. Matching is case-insensitive and,
    /// critically, `blocked` is checked before `working`: a confirmation prompt
    /// can coexist on screen with a stale interrupt hint, and the pending
    /// question is what actually needs the user. Never returns `.absent` — the
    /// caller supplies that when no agent is present.
    public func signal(fromViewport text: String) -> AgentSignal {
        let haystack = text.lowercased()

        if blockedAllOf.contains(where: { haystack.containsAll($0) }) {
            return .blocked
        }
        let isWorking =
            workingContains.contains(where: { haystack.contains($0) })
            || workingAllOf.contains(where: { haystack.containsAll($0) })
        return isWorking ? .working : .idle
    }

    /// Claude Code's on-screen affordances. Substrings are already lowercase so
    /// they compare directly against the lowercased viewport.
    public static let claudeCode = AgentDetectionRuleSet(
        workingContains: [
            "esc to interrupt",
            "press esc to interrupt",
            "ctrl+c to interrupt",
        ],
        workingAllOf: [
            ["running tools", "esc to interrupt"],
        ],
        blockedAllOf: [
            ["do you want to proceed?", "esc to cancel"],
        ])
}

extension String {
    /// True when every substring in `needles` is present.
    fileprivate func containsAll(_ needles: [String]) -> Bool {
        needles.allSatisfy { contains($0) }
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
