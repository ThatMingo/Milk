import Foundation
import CryptoKit

/// Immutable, in-memory launch inputs. Environment/provider overrides are never persisted.
struct PiLaunchContext {
    let installation: AgentInstallationRecord
    let executable: URL
    let version: String
    let integration: URL
    let supportPaths: [URL]
    let environment: [String: String]
    let providerTokenOverride: String?
    let dataProfile: AgentDataProfile
    let compatibility: AgentCompatibilityResult
    var bundled: Bool { installation.ownership == .applicationBundle }
}

struct PiLaunchResolver {
    let runtime: PiRuntimeService
    func installation(for mode: PiRuntimeMode) -> AgentInstallationRecord {
        switch mode {
        case .bundled:
            return .init(id: .init(rawValue: "pi:application-bundle"), agentID: .pi, ownership: .applicationBundle,
                         source: .applicationBundle, executable: runtime.resources.appendingPathComponent("PiRuntime/pi"))
        case .external(let url):
            return .init(id: .init(rawValue: "pi:external:" + url.standardizedFileURL.path), agentID: .pi,
                         ownership: .external, source: .userSelected, executable: url)
        }
    }
    @MainActor func resolve(_ mode: PiRuntimeMode, lifecycle: AgentLifecycleCoordinator?, probeDirectory: URL? = nil) async throws -> PiLaunchContext {
        try await resolve(installation(for: mode), lifecycle: lifecycle, probeDirectory: probeDirectory)
    }
    @MainActor func resolve(_ installation: AgentInstallationRecord, lifecycle: AgentLifecycleCoordinator?, probeDirectory: URL? = nil) async throws -> PiLaunchContext {
        var version: String?
        do {
            guard installation.agentID == .pi else { throw AgentError.message("This installation is not Pi.") }
            AgentResourceOwnership.current?.associate(installation)
            let mode: PiRuntimeMode = installation.ownership == .applicationBundle ? .bundled : .external(installation.executable)
            let location = try await Task.detached(priority: .userInitiated) { try runtime.locate(mode) }.value
            try Task.checkCancellation()
            if installation.ownership == .milkManaged {
                // Validation of an already-existing candidate only; no install/update operation.
                guard let digest = installation.executableSHA256, installation.expectedVersion != nil else {
                    throw AgentError.message("A Milk-managed candidate requires pinned version and executable integrity metadata.")
                }
                let executable = location.executable
                let actual = try await Task.detached { SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined() }.value
                guard actual == digest else { throw AgentError.message("Managed Pi candidate integrity check failed.") }
            }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(runtime.environmentOverrides) { _, new in new }
            let support: [URL]
            if location.bundled { support = [runtime.resources.appendingPathComponent("PiRuntime/bin")] }
            else {
                // Selected launcher directory supports shebang runtimes such as a sibling node.
                // Only use installation-local search tools; never borrow Milk's bundled tools.
                var paths = [location.executable.deletingLastPathComponent()]
                for root in [location.executable.deletingLastPathComponent(), location.executable.resolvingSymlinksInPath().deletingLastPathComponent()] {
                    let bin = root.appendingPathComponent("bin")
                    if ["rg", "fd"].contains(where: { FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent($0).path) }), !paths.contains(bin) { paths.append(bin) }
                }
                support = paths
            }
            environment["PATH"] = (support.map(\.path) + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
            environment["PI_OFFLINE"] = "1"
            let detected = try await runtime.version(of: location.executable, lifecycle: lifecycle, environment: environment, directory: probeDirectory)
            version = detected; try Task.checkCancellation()
            if let expected = location.manifest?.version ?? installation.expectedVersion, expected != detected {
                throw AgentError.message("Pi version does not match its pinned runtime metadata.")
            }
            let compatibility = PiCompatibilityPolicy.evaluate(version: detected)
            try PiCompatibilityPolicy.requireSupportedVersion(compatibility)
            let dataDirectory = environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
            return .init(installation: installation, executable: location.executable, version: detected,
                         integration: location.integration, supportPaths: support, environment: environment,
                         providerTokenOverride: runtime.environmentOverrides["MILK_OMLX_TOKEN"],
                         dataProfile: .init(directory: dataDirectory, ownership: probeDirectory == nil ? .sharedExisting : .ephemeralMilk), compatibility: compatibility)
        } catch is CancellationError { throw CancellationError() }
        catch let error as AgentCompatibilityError { throw error }
        catch { throw AgentCompatibilityError(result: PiCompatibilityPolicy.result(.invalidRuntime, version: version, detail: error.localizedDescription)) }
    }
}
