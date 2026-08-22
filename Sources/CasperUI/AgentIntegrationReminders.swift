import CasperCore
import Foundation
import Observation

/// The machine-wide answer to "does the user have a coding agent whose Casper
/// integration is missing, stale, or installed but not yet active?".
///
/// The policy and the probing live in CasperCore (`AgentIntegration`,
/// `AgentIntegrationProbe`); this is only the wiring: run the probe off the main
/// actor, fold the dismissals in, and publish an ordered list the sidebar can render.
/// Casper never repairs an agent's configuration — see
/// `.superpowers/themes/agent-state-detection.md` and the agent-integration policy:
/// detect and remind, nothing more.
///
/// Owned by `AppModel`, which forwards the sidebar's and the tests' entry points here
/// and injects its own `persist` — the same shape `ScriptHookRunner` and
/// `BrowserAutomationController` use. `@Observable` in its own right, so a probe
/// landing after the sidebar has already rendered still re-renders it, whether the view
/// reads `reminders` here or through `AppModel`'s forwarding property.
@MainActor
@Observable
final class AgentIntegrationReminders {
    /// One sidebar reminder line about a coding agent's Casper integration.
    struct Reminder: Identifiable, Equatable {

        /// What the line is telling the user. Not derivable from `status` alone:
        /// `.installed` means "nothing to do" for most agents, but "one manual step
        /// left" for an agent whose hooks stay inert until they are approved.
        enum Kind: Equatable {
            /// The integration is missing or stale — the user installs or updates it.
            case actionNeeded
            /// The integration is installed but does nothing until its hooks are trusted.
            case trustNotice
        }

        let agent: CodingAgent
        let status: AgentIntegrationStatus
        let kind: Kind

        /// The dismissal id, which is also the stable list identity — a row must not
        /// lose its SwiftUI identity when its status changes.
        var id: String { Self.dismissalKey(agent: agent, kind: kind) }

        var documentationURL: URL { agent.documentationURL }

        /// The key a dismissal of this line is persisted under, in
        /// `Session.dismissedAgentReminders`.
        ///
        /// The two kinds deliberately use *different* keys. `apply(_:)` retires an
        /// agent's action-needed dismissal as soon as that agent reports `.installed`.
        /// A trust notice only ever appears *while* the agent reports `.installed`, so
        /// sharing the key would un-dismiss it the instant it became relevant, leaving
        /// it impossible to silence.
        static func dismissalKey(agent: CodingAgent, kind: Kind) -> String {
            switch kind {
            case .actionNeeded: return agent.reminderID
            case .trustNotice: return "\(agent.reminderID)-trust"
            }
        }
    }

    /// How long a probe result stays fresh before a stale check re-runs one.
    ///
    /// Only the *first* probe is expensive: it resolves the three agent CLIs through
    /// `LoginShellPath`, one login shell each (1–2.5 s of real work in total). Those
    /// lookups are cached — misses included — for the lifetime of the process, so every
    /// probe after the first is a handful of `stat` and `read` calls, far too cheap to
    /// be worth rationing by the minute.
    ///
    /// Seconds are what let the reminder close its own loop. The expected way to install
    /// an integration is a `plugin install` command typed *in a Casper terminal*, which
    /// never resigns the app active, so nothing but this cadence can retire the line
    /// while the user is still looking at it.
    nonisolated static let probeInterval: TimeInterval = 5

    /// Whether a stale check should re-probe. Pure and `static` so the interval is
    /// unit-testable without a clock seam on the model.
    ///
    /// No earlier probe means there is nothing to *re*fresh — deliberately not "probe
    /// immediately": the first probe is the expensive one, and starting it belongs to
    /// the launch path, which runs it once and off the main actor.
    nonisolated static func shouldRefresh(lastProbeAt: Date?, now: Date) -> Bool {
        guard let lastProbeAt else { return false }
        return now.timeIntervalSince(lastProbeAt) >= probeInterval
    }

    /// Probes each agent's integration. Injectable so tests never spawn a login
    /// shell or read the real home directory. `@Sendable` because it is called off
    /// the main actor.
    @ObservationIgnored var probe: @Sendable () -> [CodingAgent: AgentIntegrationStatus] = {
        AgentIntegrationProbe().statuses()
    }

    /// The agents the sidebar should currently remind about, in `CodingAgent.allCases`
    /// order. Observed: it is written from a background probe completing after the
    /// view has already rendered, so the view has to re-render when it lands.
    private(set) var reminders: [Reminder] = []

    /// The last probe's raw result. Not observed — nothing renders it directly;
    /// `reminders` is the published projection.
    @ObservationIgnored private var statuses: [CodingAgent: AgentIntegrationStatus] = [:]

    /// `CodingAgent.reminderID` values the user has dismissed. Mirrors
    /// `Session.dismissedAgentReminders`: seeded from the loaded session and written
    /// back by every `persist`.
    @ObservationIgnored private(set) var dismissed: Set<String>

    /// When the last probe was *started*, or nil before the first one.
    @ObservationIgnored private var lastProbeAt: Date?

    /// The in-flight probe, if any. Deduplicates overlapping requests, is cancelled
    /// on teardown, and lets tests await a probe they just triggered.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// Save the owning session. Injected rather than reached for, so this type stays
    /// free of `AppModel`; the owner captures itself weakly.
    @ObservationIgnored private let persist: () -> Void

    init(dismissed: Set<String>, persist: @escaping () -> Void) {
        self.dismissed = dismissed
        self.persist = persist
    }

    deinit {
        // The probe outlives nothing: cancel it here rather than from the owner, which
        // would otherwise have to reach into this object from its own `deinit`.
        task?.cancel()
    }

    /// Probe now, whatever the last result's age: the launch probe, and the one the
    /// user earns by opening a reminder's documentation. A probe already in flight is
    /// left to finish.
    func refresh() {
        guard task == nil else { return }
        lastProbeAt = Date()
        let probe = self.probe
        task = Task { @MainActor [weak self] in
            // Detached, never inline: a cold `statuses()` blocks for seconds on three
            // sequential login shells, and this actor is the one drawing the UI.
            let statuses = await Task.detached(priority: .utility) { probe() }.value
            // `Task.detached` neither inherits nor forwards cancellation, and awaiting a
            // non-throwing task is not a cancellation point — so a cancelled probe runs to
            // completion and still lands here. This check is what keeps it from publishing.
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.apply(statuses)
        }
    }

    /// Re-probe if the last result is older than `probeInterval`. Called from every
    /// detection tick and on app activation, so an integration installed anywhere — a
    /// Casper terminal, another app — retires its own reminder within one interval,
    /// with no user action to ask for.
    func refreshIfStale() {
        guard Self.shouldRefresh(lastProbeAt: lastProbeAt, now: Date()) else { return }
        refresh()
    }

    /// The user opened a reminder's documentation, so an install is imminent: age the
    /// current result out so the next stale check re-probes instead of leaving the line
    /// up for the rest of the interval.
    ///
    /// Opening the URL stays with the view. Keeping `NSWorkspace` out of the model is
    /// what lets a test drive this without launching a browser.
    func documentationOpened() {
        lastProbeAt = .distantPast
    }

    /// Dismiss one reminder line, permanently as far as this problem is concerned.
    ///
    /// Keyed by `Reminder.id`, never an agent's `rawValue`: those ids outlive the
    /// process in `session.json` (`"claude-code"`, not `"claudeCode"`), so the wrong key
    /// would make every dismissal a silent no-op.
    ///
    /// A line the current result no longer publishes is ignored. The click carries a
    /// reminder captured when the view's body last ran, and a probe landing in between
    /// can have retired it — dismissing it then would persist a key for a line nobody
    /// was looking at, and `"<agent>-trust"` is the one key nothing ever retires, so a
    /// mistimed click would silence the trust notice for good. Matched on `id` rather
    /// than on the whole value, so a status changing under an unchanged line
    /// (`.missing` → `.outdated`) still lets a genuine click through.
    func dismiss(_ reminder: Reminder) {
        guard reminders.contains(where: { $0.id == reminder.id }) else { return }
        guard dismissed.insert(reminder.id).inserted else { return }
        rebuild()
        persist()
    }

    /// Publish a probe result, first retiring the dismissals it has made obsolete.
    private func apply(_ statuses: [CodingAgent: AgentIntegrationStatus]) {
        self.statuses = statuses

        // A dismissal silences the *current* problem, not the agent forever. Once an
        // agent's integration is healthy the dismissal has done its job, so drop it:
        // if the user later breaks or uninstalls that integration, they get reminded
        // again. Without this, one dismissal blinds them to that agent for good.
        //
        // Only the action-needed key is retired. A trust notice keys off `.installed`
        // itself, so clearing its key here would un-dismiss it the moment it became
        // relevant — which is exactly why it carries a key of its own.
        let healed = statuses
            .filter { $0.value == .installed }
            .map { Reminder.dismissalKey(agent: $0.key, kind: .actionNeeded) }
        let remaining = dismissed.subtracting(healed)
        if remaining != dismissed {
            dismissed = remaining
            persist()
        }
        rebuild()
    }

    /// Recompute the published list from the last probe and the dismissals.
    ///
    /// Driven by `CodingAgent.allCases` rather than by iterating the status
    /// dictionary: dictionary order depends on a per-process hash seed, so the
    /// sidebar's lines would shuffle from one launch to the next.
    private func rebuild() {
        let rebuilt = CodingAgent.allCases.compactMap { agent -> Reminder? in
            guard let status = statuses[agent],
                  let kind = Self.reminderKind(for: status, of: agent) else { return nil }
            let reminder = Reminder(agent: agent, status: status, kind: kind)
            guard !dismissed.contains(reminder.id) else { return nil }
            return reminder
        }
        guard rebuilt != reminders else { return }
        reminders = rebuilt
    }

    /// Which line, if any, a status earns. Exhaustive on purpose, so a new
    /// `AgentIntegrationStatus` case forces a decision here rather than silently
    /// defaulting to "say nothing".
    private static func reminderKind(
        for status: AgentIntegrationStatus,
        of agent: CodingAgent
    ) -> Reminder.Kind? {
        switch status {
        case .missing, .outdated: return .actionNeeded
        // The agent's CLI is absent, so the user does not use it: advertising an
        // integration for a tool they never installed is pure noise.
        case .notInstalled: return nil
        // Installed and current is normally nothing to report. The exception is an
        // agent whose hooks stay inert until approved — the install is real, but it
        // does nothing at all until the user takes that last step.
        case .installed: return agent.requiresHookTrust ? .trustNotice : nil
        }
    }
}
