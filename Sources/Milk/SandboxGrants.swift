import Foundation
import Combine

struct SandboxOperationScope: Equatable {
    let id = UUID()
    let activation: AgentActivation
}
enum SandboxGrantLifetime { case once, session }
enum SandboxOperationEnd { case finished, cancelled, timedOut, ended }
struct SandboxTemporaryGrant: Identifiable {
    let id = UUID()
    let activation: AgentActivation
    let operationID: UUID?
    let lifetime: SandboxGrantLifetime
    let path: SandboxResolvedPath
    let includesDescendants: Bool
    let access: SandboxFolderAccess
    let approval: SandboxPolicyOutcome
    let rule: SandboxPolicyRule
    let subject: SandboxSubject
    let boundaries: Set<String>
}

/// In-memory admission authority only. No process launch/cleanup or inherited-profile revocation.
@MainActor final class SandboxGrantStore: ObservableObject {
    @Published private(set) var grants: [SandboxTemporaryGrant] = []
    private var runtimes: [UUID: AgentActivation] = [:]
    private var operations: [UUID: SandboxOperationScope] = [:]
    private var accepting = true
    private var retiredActivations: Set<UUID> = []
    // Lifecycle is the owner. Tokens are fresh per activation, never reconstructed from chat history.
    @discardableResult func register(_ activation: AgentActivation) -> Bool {
        guard accepting, !retiredActivations.contains(activation.token), runtimes[activation.token] == nil else { return false }
        runtimes[activation.token] = activation; return true
    }
    func beginOperation(in activation: AgentActivation) throws -> SandboxOperationScope {
        guard accepting, runtimes[activation.token] == activation else { throw CancellationError() }
        let scope = SandboxOperationScope(activation: activation); operations[scope.id] = scope; return scope
    }
    private func isLive(_ operation: SandboxOperationScope) -> Bool {
        accepting && runtimes[operation.activation.token] == operation.activation && operations[operation.id] == operation
    }
    @discardableResult func approve(_ decision: SandboxPolicyDecision, access: SandboxFolderAccess,
                                   lifetime: SandboxGrantLifetime, operation: SandboxOperationScope,
                                   includesDescendants: Bool = false) throws -> SandboxTemporaryGrant {
        guard isLive(operation), decision.subject != .agentRuntime, decision.requiresApproval, let path = decision.path,
              path.revalidated(), access.permits(decision.action),
              !(decision.outcome == .requireProtectedLocationApproval && lifetime == .session),
              !includesDescendants || path.isDirectory else { throw SandboxSettingsError.message("This approval is stale or outside its permitted scope.") }
        let grant = SandboxTemporaryGrant(activation: operation.activation, operationID: lifetime == .once ? operation.id : nil,
                                         lifetime: lifetime, path: path, includesDescendants: includesDescendants,
                                         access: access, approval: decision.outcome, rule: decision.rule, subject: decision.subject, boundaries: decision.boundaries)
        grants.append(grant); return grant
    }
    /// Always re-evaluate current policy first, then apply matching live grants. A grant
    /// cannot override a deny, a new Protected Location, inactive profile or Project R/O.
    func admitting(_ decision: SandboxPolicyDecision, operation: SandboxOperationScope) -> SandboxPolicyDecision {
        guard isLive(operation) else { return .init(outcome: .deny, rule: .staleOwnership, action: decision.action, path: decision.path) }
        if let path = decision.path, !path.revalidated() { return .init(outcome: .deny, rule: .unresolvedPath, action: decision.action, path: path, subject: decision.subject) }
        guard decision.subject != .agentRuntime, decision.requiresApproval, let path = decision.path else { return decision }
        let matching = grants.contains {
            $0.activation == operation.activation && ($0.operationID == nil || $0.operationID == operation.id)
                && $0.access.permits(decision.action) && $0.approval == decision.outcome
                && $0.subject == decision.subject && $0.rule == decision.rule && $0.boundaries == decision.boundaries && $0.path.revalidated()
                && ($0.includesDescendants ? $0.path.contains(path) : $0.path.canonicalURL == path.canonicalURL)
        }
        return matching ? .init(outcome: .allow, rule: .temporaryGrant, action: decision.action, path: path, boundaries: decision.boundaries, subject: decision.subject) : decision
    }
    func end(_ operation: SandboxOperationScope, reason: SandboxOperationEnd) {
        guard operations[operation.id] == operation else { return }
        // Close future admission before any later asynchronous process cleanup can run.
        operations[operation.id] = nil; grants.removeAll { $0.operationID == operation.id }
    }
    func revokeSessionGrant(_ id: UUID) { grants.removeAll { $0.id == id && $0.lifetime == .session } }
    func invalidate(_ activation: AgentActivation) {
        guard runtimes[activation.token] == activation else { return }
        retiredActivations.insert(activation.token)
        runtimes[activation.token] = nil
        operations = operations.filter { $0.value.activation != activation }
        grants.removeAll { $0.activation == activation }
    }
    func shutdown() { accepting = false; runtimes.removeAll(); operations.removeAll(); grants.removeAll() }
}
