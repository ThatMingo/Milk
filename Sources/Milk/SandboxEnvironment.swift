import Foundation

/// Typed host-selected toolchain input. Never inferred from an agent/worker dictionary.
struct SandboxToolchainEnvironment {
    var developerDirectory: URL? = nil
    init(source: [String:String] = [:]) throws {
        if let value = source["DEVELOPER_DIR"] {
            guard value.hasPrefix("/"), !value.utf8.contains(0),
                  let path = try? SandboxPathResolver().resolve(URL(fileURLWithPath:value)), path.isDirectory else {
                throw AgentError.message("DEVELOPER_DIR must select an existing absolute developer directory.")
            }
            developerDirectory = path.canonicalURL
        }
    }
}

/// Common secret-free boundary for Milk executors and future native extension workers.
/// No ambient or agent-supplied environment dictionary is accepted.
enum SandboxEnvironment {
    static let systemPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static func path(support: [URL], ambient: String? = nil) -> String {
        var paths: [String] = []
        for value in support.map(\.path) + (ambient?.components(separatedBy: ":") ?? []) + systemPath {
            guard value.hasPrefix("/"), !value.contains(":"), !value.utf8.contains(0), !paths.contains(value) else { continue }
            paths.append(value)
        }
        return paths.joined(separator: ":")
    }
    static func execution(home: URL, temporary: URL, support: [URL], toolchain: SandboxToolchainEnvironment? = nil) -> [String:String] {
        var result = ["HOME":home.path,"TMPDIR":temporary.path,"PATH":path(support:support),
                      "LANG":"en_US.UTF-8","SHELL":"/bin/zsh"]
        if let developer = toolchain?.developerDirectory { result["DEVELOPER_DIR"] = developer.path }
        return result
    }
}
