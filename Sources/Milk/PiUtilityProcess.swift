import Foundation
import Darwin
import Combine

/// Owns only the existing short-lived --version and package CLI commands.
/// Conversation RPC retains its original EOF/TERM/KILL implementation.
@MainActor final class PiUtilityProcess: AgentOwnedResource {
    private var sandboxChild: SandboxProcess?
    private var child: Process?
    private var completion: Task<(Data, Int32), Never>?
    private var closing = false

    private func run(executable: URL, arguments: [String], directory: URL?, environment: [String: String]?, timeout: Double, mergeErrors: Bool, sandboxProfile: String? = nil) async throws -> (Data, Int32) {
        guard !closing else { throw CancellationError() }
        if let sandboxProfile {
            let command = SandboxProfileBuilder.command(executable: executable, arguments: arguments, profile: sandboxProfile)
            let input = Pipe(), output = Pipe(), errors = Pipe()
            let owned = try SandboxProcess(executable: command.0, arguments: command.1, directory: directory!, environment: environment ?? [:], input: input, output: output, errors: errors)
            sandboxChild = owned; try? input.fileHandleForWriting.close()
            let watchdog = DispatchWorkItem { owned.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let stderr = Task.detached { var bytes = Data(); while true { let chunk = owned.read(errors.fileHandleForReading); if chunk.isEmpty { break }; if mergeErrors, bytes.count < 8*1024*1024 { bytes.append(chunk) } }; return bytes }
            let task = Task.detached { var bytes = Data(); while true { let chunk = owned.read(output.fileHandleForReading); if chunk.isEmpty { break }; if bytes.count < 8*1024*1024 { bytes.append(chunk) } }; owned.waitUntilExit(); watchdog.cancel(); return (bytes + (await stderr.value), owned.terminationStatus) }
            completion = task; let result = await task.value; try Task.checkCancellation(); return result
        }
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
        sandboxChild?.terminate()
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
    func shutdownAndWait() async throws { shutdown(); _ = await completion?.value }

    static func execute(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
                        timeout: Double, mergeErrors: Bool = false, purpose: AgentBackendPurpose,
                        lifecycle: AgentLifecycleCoordinator?, plan suppliedPlan: SandboxPurposePlan? = nil, support: [URL] = [], codeRoot: URL? = nil) async throws -> (Data, Int32) {
        let owner = lifecycle ?? AgentLifecycleCoordinator()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Purpose-" + UUID().uuidString)
        defer { if suppliedPlan == nil { try? FileManager.default.removeItem(at:temporary) } }
        let authority=SandboxLaunchAuthority.capture()
        let plan: SandboxPurposePlan
        if let suppliedPlan { guard suppliedPlan.purpose == purpose else { throw AgentError.message("Utility purpose mismatch.") }; plan=suppliedPlan }
        else if purpose == .versionProbe {
            plan=try SandboxPurposePlan.make(purpose:purpose,executable:executable,authority:authority,root:temporary,sourceEnvironment:environment ?? [:],explicitEnvironment:environment ?? [:],support:support,codeRoot:codeRoot,runtimeDependencies:PiRuntimeService.supportRoots(executable:executable))
        } else { throw AgentError.message("This utility requires an explicit purpose/source/profile contract.") }
        try plan.check()
        var result: (Data, Int32)?
        let lease = owner.begin(activation: .init(agentID: .pi, workspace: directory ?? executable.deletingLastPathComponent(), sessionID: -1),
                                purpose: purpose, factory: { PiUtilityProcess() }) { resource, lease in
            let process = resource as! PiUtilityProcess
            let observation=plan.observe { process.shutdown() }; defer { observation?.cancel() }
            try plan.check()
            result = try await process.run(executable:plan.closure.executable,arguments:arguments,directory:plan.workspace,environment:plan.environment,timeout:timeout,mergeErrors:mergeErrors,sandboxProfile:plan.profile)
            try plan.check()
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
