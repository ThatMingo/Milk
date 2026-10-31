import Foundation
import Darwin

/// Owns only the existing short-lived --version and package CLI commands.
/// Conversation RPC retains its original EOF/TERM/KILL implementation.
@MainActor final class PiUtilityProcess: AgentOwnedResource {
    private var child: Process?
    private var completion: Task<(Data, Int32), Never>?
    private var closing = false

    private func run(executable: URL, arguments: [String], directory: URL?, environment: [String: String]?, timeout: Double, mergeErrors: Bool) async throws -> (Data, Int32) {
        guard !closing else { throw CancellationError() }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardOutput = output; process.standardError = mergeErrors ? output : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); child = process
        let watchdog = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let task = Task.detached(priority: .utility) {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); watchdog.cancel()
            return (data, process.terminationStatus)
        }
        completion = task
        let result = await task.value
        try Task.checkCancellation()
        return result
    }
    func shutdown() {
        closing = true
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    func shutdownAndWait() async throws { shutdown(); _ = await completion?.value }

    static func execute(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
                        timeout: Double, mergeErrors: Bool = false, purpose: AgentBackendPurpose,
                        lifecycle: AgentLifecycleCoordinator?) async throws -> (Data, Int32) {
        let owner = lifecycle ?? AgentLifecycleCoordinator()
        var result: (Data, Int32)?
        let lease = owner.begin(activation: .init(agentID: .pi, workspace: directory ?? executable.deletingLastPathComponent(), sessionID: -1),
                                purpose: purpose, factory: { PiUtilityProcess() }) { resource, lease in
            let process = resource as! PiUtilityProcess
            result = try await process.run(executable: executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout, mergeErrors: mergeErrors)
            try lease.check()
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try await lease.work.value; try Task.checkCancellation()
                try await owner.stopAndWait(lease)
                return result!
            } catch {
                try await owner.stopAndWait(lease)
                throw error
            }
        }, onCancel: { Task { @MainActor in owner.stop(lease) } })
    }
}
