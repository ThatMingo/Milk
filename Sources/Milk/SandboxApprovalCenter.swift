import Foundation

@MainActor final class SandboxApprovalCenter {
    static let unavailable = "Access was denied because the user is temporarily unavailable. Do not immediately repeat the same request. Continue with other work and retry later only if still necessary."
    struct Pending { let continuation: CheckedContinuation<SandboxGrantLifetime, Error>; let protected: Bool; let key: String }
    private var pending: [String: Pending] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var timedOut: [String: Date] = [:]
    var event: ((AgentEvent) -> Void)?
    func request(_ decision: SandboxPolicyDecision, operation: SandboxOperationScope, tool: String, command: String?, mode: ComposerPermissionMode, timeout: Double) async throws -> SandboxGrantLifetime {
        guard let path = decision.path, decision.requiresApproval else { throw SandboxPathError.invalidPath }
        let key = [tool, command ?? "", path.canonicalURL.path, decision.action.rawValue].joined(separator: "\n")
        if let denied = timedOut[key], Date().timeIntervalSince(denied) < 15 { throw AgentError.message(Self.unavailable) }
        let id = "milk-sandbox-" + UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let protected = decision.outcome == .requireProtectedLocationApproval
                pending[id] = .init(continuation: continuation, protected: protected, key: key)
                var request = AgentApproval(id: id, method: .select, title: protected ? "Protected Location access" : "Sandbox permission required",
                    message: "", options: protected ? ["Deny", "Sandbox Settings", "Allow Once"] : ["Deny", "Allow for Session", "Allow Once"],
                    tool: tool, action: path.canonicalURL.path, command: command, workingDirectory: operation.activation.workspace.path,
                    reason: "\(decision.action.rawValue.capitalized) access requested by \(tool).",
                    effect: protected ? "This location may contain credentials or authentication data. Access applies only to this operation." : "The permission applies to sibling execution, never the fixed agent runtime.",
                    risk: protected ? "Protected" : nil, origin: .milkSandbox, activation: operation.activation)
                if mode == .autonomous { request.sandboxDeadline = Date().addingTimeInterval(timeout) }
                event?(.approval(request))
                if mode == .autonomous {
                    timers[id] = Task { [weak self] in
                        let end = Date().addingTimeInterval(timeout)
                        while Date() < end {
                            do { try await Task.sleep(nanoseconds: UInt64(min(60, max(0.001, end.timeIntervalSinceNow)) * 1_000_000_000)) }
                            catch { return }
                        }
                        guard let self, let item = self.pending[id] else { return }
                        self.timedOut = self.timedOut.filter { Date().timeIntervalSince($0.value) < 60 }
                        self.timedOut[item.key] = Date()
                        self.finish(id, .failure(AgentError.message(Self.unavailable)))
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) } })
    }
    func respond(_ request: AgentApproval, response: AgentDialogResponse) throws {
        guard let item = pending[request.id] else { throw CancellationError() }
        switch response {
        case .value("Allow Once"): finish(request.id, .success(.once))
        case .value("Allow for Session") where !item.protected: finish(request.id, .success(.session))
        default: finish(request.id, .failure(AgentError.message("Sandbox access was denied or cancelled.")))
        }
    }
    private func finish(_ id: String, _ result: Result<SandboxGrantLifetime, Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel(); event?(.dismissApproval(id)); item.continuation.resume(with: result)
    }
    func cancelAll() { for id in Array(pending.keys) { finish(id, .failure(CancellationError())) } }
}
