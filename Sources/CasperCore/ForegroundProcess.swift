import Foundation

// Identifies what runs in the foreground of a terminal, so agent detection can
// pick the matching rule set, read a shell prompt as "no agent", and see an
// agent exit.
//
// The terminal reports its foreground process group (`tcgetpgrp` on the PTY);
// this file turns that PID into a `ForegroundProcess`. The classifier and the
// tracker are pure; `LibprocProcessInspector` is the one thin reader of the
// kernel's process table behind the `ProcessInspector` seam.
//
// The kernel's process name alone does not identify an agent: native Claude
// Code runs from a versioned file, so its `p_comm` is its version (`2.1.319`),
// and npm installs run a native binary named `claude.exe`. Classification
// therefore weighs argv[0] and the executable paths alongside it.

/// What occupies a terminal's foreground, as far as agent detection cares.
public enum ForegroundProcess: Equatable, Sendable {
    /// A known coding agent leads the foreground group.
    case agent(CodingAgent)
    /// An interactive shell sits alone in its group: the prompt, no job running.
    case shell
    /// Readable, but neither a known agent nor a lone shell (`vim`, `ssh`, a
    /// script). `name` is the process's kernel name (`comm`), which it cannot
    /// rewrite the way it can its argv, for diagnostics.
    case other(name: String)
    /// The foreground is unknown, or its leader could not be read.
    case unidentified
}

/// What the classifier reads about one process. Plain data, so tests build it.
public struct ProcessSnapshot: Equatable, Sendable {
    public var pid: pid_t
    /// The kernel's `p_comm` (`pbi_comm`, at most 16 bytes).
    public var comm: String
    /// The executable's path with symlinks resolved (`proc_pidpath`).
    public var imagePath: String?
    /// The executable's path as invoked (the head of `KERN_PROCARGS2`).
    public var execPath: String?
    /// The arguments, `argv[0]` first (`KERN_PROCARGS2`). Empty when unreadable.
    public var argv: [String]
    /// How many processes share the group this process leads.
    public var groupSize: Int?

    public init(
        pid: pid_t, comm: String, imagePath: String?, execPath: String?, argv: [String], groupSize: Int?
    ) {
        self.pid = pid
        self.comm = comm
        self.imagePath = imagePath
        self.execPath = execPath
        self.argv = argv
        self.groupSize = groupSize
    }
}

/// The cheap identity of a process: a changed key means a new program.
///
/// `comm` is part of it because `exec` keeps the PID: `exec claude` from the
/// shell, or the Codex shim `execve`-ing into the native binary.
public struct ProcessKey: Hashable, Sendable {
    public var pid: pid_t
    public var comm: String

    public init(pid: pid_t, comm: String) {
        self.pid = pid
        self.comm = comm
    }
}

/// Reads processes from the system. `key(of:)` runs on every detection tick;
/// `snapshot(of:)` only when the key changes.
///
/// Every method answers `nil` for a process it cannot read (gone, or another
/// user's), never traps.
public protocol ProcessInspector {
    func key(of pid: pid_t) -> ProcessKey?
    func snapshot(of pid: pid_t) -> ProcessSnapshot?
    /// The number of processes in the group `pgid`.
    func groupSize(of pgid: pid_t) -> Int?
    /// The basenames of every shell the user may run.
    var shellNames: Set<String> { get }
}

// MARK: - Classifier

/// Turns a `ProcessSnapshot` into a `ForegroundProcess`.
public enum ForegroundProcessClassifier {
    /// Runtimes that run an agent as a script: the script names the agent.
    private static let interpreters: Set<String> = ["node", "bun", "deno"]
    private static let scriptExtensions = [".js", ".mjs", ".cjs"]

    /// Classifies a snapshot, or `.unidentified` when there is none.
    ///
    /// An agent's name wins over everything, matched exactly (`claude-monitor`
    /// is not Claude Code). A shell counts only when it is alone in its group:
    /// a non-interactive shell does no job control, so a script wrapping an
    /// agent leaves the shell leading a group that holds the agent.
    public static func classify(_ snapshot: ProcessSnapshot?, shellNames: Set<String>) -> ForegroundProcess {
        guard let snapshot else { return .unidentified }
        let candidates = candidateNames(of: snapshot)
        if let agent = agent(named: candidates) {
            return .agent(agent)
        }
        if hasShellName(candidates, shellNames: shellNames) && snapshot.groupSize == 1 {
            return .shell
        }
        return .other(name: snapshot.comm)
    }

    /// Whether the snapshot would classify as `.shell` were it alone in its
    /// group. The tracker uses it to know which cached processes need their
    /// group re-counted.
    static func isShell(_ snapshot: ProcessSnapshot, shellNames: Set<String>) -> Bool {
        let candidates = candidateNames(of: snapshot)
        return agent(named: candidates) == nil && hasShellName(candidates, shellNames: shellNames)
    }

    private static func agent(named candidates: [String]) -> CodingAgent? {
        for name in candidates {
            if let agent = CodingAgent.allCases.first(where: { $0.executableNames.contains(name) }) {
                return agent
            }
        }
        return nil
    }

    private static func hasShellName(_ candidates: [String], shellNames: Set<String>) -> Bool {
        candidates.contains { shellNames.contains($0) }
    }

    /// The names a process answers to, in order of trust: `argv[0]` as typed,
    /// then the invoked and the resolved executable, then the kernel's name.
    /// Behind an interpreter, the script it runs comes last.
    private static func candidateNames(of snapshot: ProcessSnapshot) -> [String] {
        var names: [String] = []
        if let argv0 = snapshot.argv.first {
            // A login shell's argv[0] is `-zsh` or `-/bin/zsh`.
            names.append(normalized(basename(String(argv0.trimmingPrefix("-")))))
        }
        if let execPath = snapshot.execPath {
            names.append(normalized(basename(execPath)))
        }
        if let imagePath = snapshot.imagePath {
            names.append(normalized(basename(imagePath)))
        }
        names.append(normalized(snapshot.comm))

        let runsAScript = names.contains { interpreters.contains($0) }
        if runsAScript && snapshot.argv.count > 1 {
            var script = normalized(basename(snapshot.argv[1]))
            if let ext = scriptExtensions.first(where: { script.hasSuffix($0) }) {
                script.removeLast(ext.count)
            }
            names.append(script)
        }
        return names.filter { !$0.isEmpty }
    }

    /// Lower-cased, with the `.exe` an npm install gives its native binary removed.
    private static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(".exe".count)
        }
        return name
    }
}

/// The last path component of `path`.
private func basename(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}

// MARK: - Tracker

/// One surface's foreground, observed on one detection tick.
public struct ForegroundObservation: Equatable, Sendable {
    public var process: ForegroundProcess
    /// This observation ended an agent's run: the shell is back in front of a
    /// surface whose last identified foreground was an agent.
    public var agentExited: Bool

    public init(process: ForegroundProcess, agentExited: Bool) {
        self.process = process
        self.agentExited = agentExited
    }
}

/// Classifies each surface's foreground once per tick, caching the expensive
/// read per process, and spots an agent's exit.
///
/// A value type owned by the detection tick, keyed by surface id.
public struct ForegroundTracker: Sendable {
    /// The classification of one readable foreground leader.
    private struct Classified: Sendable {
        var key: ProcessKey
        /// A shell's group is re-counted on every call: it is what tells a prompt
        /// from a script, and a prompt's own command substitutions join it briefly.
        var isShell: Bool
        var process: ForegroundProcess
    }

    private struct SurfaceState: Sendable {
        var classified: Classified?
        var current: ForegroundProcess = .unidentified
        /// The last kind other than `.unidentified`, so the tick on which the
        /// dead agent's group is still foreground does not hide its exit.
        var lastIdentified: ForegroundProcess?
    }

    private var surfaces: [UUID: SurfaceState] = [:]

    public init() {}

    /// Observes `surface`'s foreground process group, `nil` when the terminal
    /// could not report one.
    public mutating func observe(
        surface: UUID, foregroundPID: pid_t?, inspector: some ProcessInspector
    ) -> ForegroundObservation {
        var state = surfaces[surface] ?? SurfaceState()

        var process = ForegroundProcess.unidentified
        var isShellWithAChild = false
        if let pid = foregroundPID, let key = inspector.key(of: pid) {
            let classified = classify(key: key, cached: state.classified, inspector: inspector)
            state.classified = classified
            if let classified {
                process = classified.process
                isShellWithAChild = classified.isShell && process != .shell
            }
        }

        // `.unidentified` and a shell with a child leave the last identified kind
        // alone, so neither hides an agent's exit: back at the prompt, the shell's
        // own `$(…)` substitutions join its group for an instant.
        var agentExited = false
        if process != .unidentified && !isShellWithAChild {
            if process == .shell, case .agent = state.lastIdentified {
                agentExited = true
            }
            state.lastIdentified = process
        }
        state.current = process
        surfaces[surface] = state
        return ForegroundObservation(process: process, agentExited: agentExited)
    }

    /// Forgets every surface not in `surfaces`, such as a closed pane.
    public mutating func retain(surfaces kept: Set<UUID>) {
        surfaces = surfaces.filter { kept.contains($0.key) }
    }

    /// The last observed foreground of `surface`, `nil` if never observed.
    public func process(for surface: UUID) -> ForegroundProcess? {
        surfaces[surface]?.current
    }

    /// Reuses `cached` while the key is unchanged, re-counting a shell's group;
    /// otherwise takes a fresh snapshot. `nil` when the snapshot cannot be read.
    private func classify(
        key: ProcessKey, cached: Classified?, inspector: some ProcessInspector
    ) -> Classified? {
        if var cached, cached.key == key {
            if cached.isShell {
                let isAlone = inspector.groupSize(of: key.pid) == 1
                cached.process = isAlone ? .shell : .other(name: key.comm)
            }
            return cached
        }
        let shellNames = inspector.shellNames
        guard let snapshot = inspector.snapshot(of: key.pid) else { return nil }
        return Classified(
            key: key,
            isShell: ForegroundProcessClassifier.isShell(snapshot, shellNames: shellNames),
            process: ForegroundProcessClassifier.classify(snapshot, shellNames: shellNames))
    }
}

// MARK: - Live inspector

/// Reads the kernel's process table through libproc and `sysctl`.
///
/// A class because it reuses its scratch buffers across calls, notably the
/// `KERN_ARGMAX`-sized one for `KERN_PROCARGS2`. Deliberately not `Sendable`:
/// the compiler then keeps each instance inside one isolation domain (the main
/// actor's detection tick) without `@MainActor`, which would also isolate its
/// `ProcessInspector` conformance and the generic code that takes it.
public final class LibprocProcessInspector: ProcessInspector {
    public let shellNames: Set<String>

    /// Receives `KERN_PROCARGS2`: argc, the exec path, argv, then the environment.
    private var argumentsBuffer: [UInt8]
    /// Receives a group's PIDs. Only "one or more than one" matters, so a group
    /// larger than this reads as this many.
    private var groupBuffer = [pid_t](repeating: 0, count: 64)

    public init() {
        argumentsBuffer = [UInt8](repeating: 0, count: Self.argumentsMax())
        let etcShells = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        shellNames = Self.shellNames(etcShells: etcShells, loginShell: Self.loginShell())
    }

    public func key(of pid: pid_t) -> ProcessKey? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // `pbi_comm` is a fixed C array, NUL-terminated only when shorter than it.
        let comm = withUnsafeBytes(of: info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessKey(pid: pid, comm: comm)
    }

    /// `nil` when the process or its arguments cannot be read. With the process
    /// readable, a failed arguments read is a race (an exit, or an `exec` in
    /// flight): failing the snapshot lets the tracker retry on its next tick
    /// rather than cache a classification made without argv, which is what
    /// identifies native Claude Code. The image path alone may be missing: argv
    /// still names the process.
    public func snapshot(of pid: pid_t) -> ProcessSnapshot? {
        guard let key = key(of: pid), let arguments = arguments(of: pid) else { return nil }
        return ProcessSnapshot(
            pid: pid,
            comm: key.comm,
            imagePath: Self.imagePath(of: pid),
            execPath: arguments.execPath,
            argv: arguments.argv,
            groupSize: groupSize(of: pid))
    }

    public func groupSize(of pgid: pid_t) -> Int? {
        // Given a buffer, `proc_listpgrppids` returns how many PIDs it wrote.
        // Given NULL, it returns a system-wide estimate instead, never the size
        // of the group, so a real buffer is always passed.
        let capacity = Int32(groupBuffer.count * MemoryLayout<pid_t>.size)
        let count = proc_listpgrppids(pgid, &groupBuffer, capacity)
        return count > 0 ? Int(count) : nil
    }

    private func arguments(of pid: pid_t) -> (execPath: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentsBuffer.count
        let status = argumentsBuffer.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return Self.parseArguments(argumentsBuffer[..<size])
    }

    /// Parses a `KERN_PROCARGS2` record: a native-endian `Int32` argc, the exec
    /// path, NUL padding, then argc NUL-terminated arguments (the environment
    /// that follows is ignored). `nil` when the record is truncated before the
    /// exec path ends.
    static func parseArguments(_ record: ArraySlice<UInt8>) -> (execPath: String, argv: [String])? {
        let argcSize = MemoryLayout<Int32>.size
        guard record.count >= argcSize else { return nil }
        let argc = record.prefix(argcSize).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }

        var rest = record.dropFirst(argcSize)
        guard let execPath = nextString(&rest) else { return nil }
        rest = rest.drop { $0 == 0 }

        var argv: [String] = []
        while argv.count < argc, let argument = nextString(&rest) {
            argv.append(argument)
        }
        return (execPath, argv)
    }

    /// Reads the NUL-terminated string at the head of `bytes` and consumes it.
    private static func nextString(_ bytes: inout ArraySlice<UInt8>) -> String? {
        guard let end = bytes.firstIndex(of: 0) else { return nil }
        let string = String(decoding: bytes[..<end], as: UTF8.self)
        bytes = bytes[bytes.index(after: end)...]
        return string
    }

    private static func imagePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift cannot import; this is its value.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }

    private static func argumentsMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentsMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), &argumentsMax, &size, nil, 0) == 0, argumentsMax > 0 else {
            // The macOS value, should the query ever fail.
            return 1 << 20
        }
        return Int(argumentsMax)
    }

    /// The user's login shell, which `login` launches even when `/etc/shells`
    /// does not list it (`fish`, `nu`).
    private static func loginShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    /// The basenames of the paths `/etc/shells` lists, plus the login shell's.
    static func shellNames(etcShells: String, loginShell: String?) -> Set<String> {
        var paths = etcShells
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if let loginShell {
            paths.append(loginShell)
        }
        return Set(paths.map { basename($0).lowercased() }.filter { !$0.isEmpty })
    }
}
