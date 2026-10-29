import Foundation

public struct PiInstallation: Sendable {
    public let executable: URL
    public let version: String
    public let environment: [String: String]
}
public enum PiDiscovery {
    public static func discover(path: String? = nil) async throws -> PiInstallation {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin"] + (environment["PATH"] ?? "").components(separatedBy: ":") + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        environment["PATH"] = directories.joined(separator: ":")
        environment["PI_TELEMETRY"] = "0"
        let candidates = path.map { [$0] } ?? directories.map { $0 + "/pi" }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw MilkError.message("Pi not found. Select the existing Pi executable in Settings.") }
        guard directories.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/node") }) else { throw MilkError.message("Node was not found. Pi’s interpreter must be available on PATH.") }
        let executable = URL(fileURLWithPath: found)
        let result = try await CommandRunner.run(.init(executable: executable, arguments: ["--version"], environment: environment))
        let version = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, version == "1.4.0" else { throw MilkError.message("Unsupported Pi version: \(version). This build is validated with Pi 1.4.0.") }
        return PiInstallation(executable: executable, version: version, environment: environment)
    }
    public static var companionURL: URL { Bundle.module.url(forResource: "milk-companion", withExtension: "mjs", subdirectory: "Resources")! }
}
