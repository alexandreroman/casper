import GhosttyKit

/// Swift-native description of a terminal surface, marshaled into a
/// `ghostty_surface_config_s` for `ghostty_surface_new`. Strings and the env
/// array are only valid inside `withCValue`'s `body` closure (they live on the
/// stack of nested `withCString` calls and are freed once it returns).
public struct GhosttySurfaceConfiguration {
    public var workingDirectory: String?
    /// Text queued into the PTY right after surface creation, consumed by the
    /// shell once it starts reading — as if typed. It is injected by
    /// `GhosttySurface.init` through the UTF-8-safe `ghostty_surface_text` path,
    /// NOT via libghostty's own `initial_input` config field: that field mojibakes
    /// non-ASCII text (it expands each byte as a Latin-1 scalar), so this struct
    /// deliberately leaves `ghostty_surface_config_s.initial_input` null.
    ///
    /// Unlike libghostty's own `command` config field
    /// (`ghostty_surface_config_s.command`, left intentionally unused here), which
    /// the vendored fork always execs via a hardcoded `bash -l -c` — ignoring the
    /// user's real login shell — this text is fed to whatever shell libghostty
    /// actually launches, so it inherits the user's real `$SHELL`/PATH. See the
    /// `surface-command-bash-exec` project memory note.
    public var initialInput: String?
    public var environment: [String: String]
    public var scaleFactor: Double
    public var fontSize: Float

    public init(
        workingDirectory: String? = nil,
        initialInput: String? = nil,
        environment: [String: String] = [:],
        scaleFactor: Double = 1.0,
        fontSize: Float = 0  // 0 → libghostty default
    ) {
        self.workingDirectory = workingDirectory
        self.initialInput = initialInput
        self.environment = environment
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize
    }

    /// Build a `ghostty_surface_config_s` valid for the duration of `body`. The
    /// `wait_after_command` and `context` fields are left at libghostty's
    /// intended default from `ghostty_surface_config_new()`.
    ///
    /// `userdata` is handed back verbatim to libghostty's clipboard/close
    /// callbacks, so the caller can recover the owning view from it.
    public func withCValue<R>(
        nsview: UnsafeMutableRawPointer,
        userdata: UnsafeMutableRawPointer?,
        _ body: (inout ghostty_surface_config_s) -> R
    ) -> R {
        var c = ghostty_surface_config_new()
        c.platform_tag = GHOSTTY_PLATFORM_MACOS
        c.platform.macos.nsview = nsview
        c.userdata = userdata
        c.scale_factor = scaleFactor
        c.font_size = fontSize

        // Flatten the env dict into parallel C-string storage, then an array of
        // ghostty_env_var_s pointing into it. `keys` and `values` iterate in
        // corresponding order, so they line up index-for-index.
        let envKeys = Array(environment.keys)
        let envValues = Array(environment.values)
        return withCStrings(envKeys) { keys in
            withCStrings(envValues) { values in
                var envVars = [ghostty_env_var_s]()
                envVars.reserveCapacity(environment.count)
                for i in envKeys.indices {
                    envVars.append(ghostty_env_var_s(key: keys[i], value: values[i]))
                }
                return withOptionalCString(workingDirectory) { wd in
                    c.working_directory = wd
                    return envVars.withUnsafeMutableBufferPointer { buf in
                        c.env_vars = buf.baseAddress
                        c.env_var_count = buf.count
                        return body(&c)
                    }
                }
            }
        }
    }
}

/// Call `body` with an array of C strings valid for its duration.
private func withCStrings<R>(
    _ strings: [String], _ body: ([UnsafePointer<CChar>]) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>]) -> R {
        if index == strings.count { return body(acc) }
        return strings[index].withCString { ptr in
            recurse(index + 1, acc + [ptr])
        }
    }
    return recurse(0, [])
}

private func withOptionalCString<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
