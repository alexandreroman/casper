import GhosttyKit

/// Swift-native description of a terminal surface, marshaled into a
/// `ghostty_surface_config_s` for `ghostty_surface_new`. Strings and the env
/// array are only valid inside `withCValue`'s `body` closure (they live on the
/// stack of nested `withCString` calls and are freed once it returns).
public struct GhosttySurfaceConfiguration {
    public var workingDirectory: String?
    public var command: String?
    public var environment: [String: String]
    public var scaleFactor: Double
    public var fontSize: Float

    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:],
        scaleFactor: Double = 1.0,
        fontSize: Float = 0  // 0 → libghostty default
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize
    }

    /// Build a `ghostty_surface_config_s` valid for the duration of `body`. All
    /// other fields (`userdata`, `initial_input`, `wait_after_command`,
    /// `context`) are left at libghostty's intended default from
    /// `ghostty_surface_config_new()`.
    public func withCValue<R>(
        nsview: UnsafeMutableRawPointer,
        _ body: (inout ghostty_surface_config_s) -> R
    ) -> R {
        var c = ghostty_surface_config_new()
        c.platform_tag = GHOSTTY_PLATFORM_MACOS
        c.platform.macos.nsview = nsview
        c.scale_factor = scaleFactor
        c.font_size = fontSize

        // Flatten the env dict into parallel C-string storage, then an array of
        // ghostty_env_var_s pointing into it.
        let pairs = environment.map { ($0.key, $0.value) }
        return withCStrings(pairs.map { $0.0 }) { keys in
            withCStrings(pairs.map { $0.1 }) { values in
                var envVars = [ghostty_env_var_s]()
                envVars.reserveCapacity(pairs.count)
                for i in pairs.indices {
                    envVars.append(ghostty_env_var_s(key: keys[i], value: values[i]))
                }
                return withOptionalCString(workingDirectory) { wd in
                    withOptionalCString(command) { cmd in
                        c.working_directory = wd
                        c.command = cmd
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
