import Foundation

/// Transport-independent ownership: a resource may be a process, SDK session or connection.
@MainActor protocol AgentOwnedResource: AnyObject {
    func shutdown()
    func shutdownAndWait() async throws
}
/// A composite asynchronous operation whose child resources have their own leases.
@MainActor final class AgentOperationResource: AgentOwnedResource {
    func shutdown() {}
    func shutdownAndWait() async throws {}
}

enum AgentWriterKey: Hashable {
    case native(AgentID, URL, String)
    case file(AgentID, String)
    static func session(_ session: AgentSession, agent: AgentID, workspace: URL) -> Set<Self> {
        var keys: Set<Self> = [.native(agent, workspace.resolvingSymlinksInPath(), session.backendID)]
        if let path = session.sessionFile { keys.insert(.file(agent, URL(fileURLWithPath: path).resolvingSymlinksInPath().path)) }
        return keys
    }
}

@MainActor final class AgentRuntimeLease {
    enum Phase { case starting, running, stopping, stopped, failed }
    let activation: AgentActivation
    let purpose: AgentBackendPurpose
    fileprivate(set) var writers: Set<AgentWriterKey>
    fileprivate(set) var phase: Phase = .starting
    fileprivate(set) var valid = true
    fileprivate(set) var resource: (any AgentOwnedResource)?
    private(set) var installation: AgentInstallationRecord?
    func associate(_ installation: AgentInstallationRecord) { self.installation = installation }
    fileprivate(set) var work: Task<Void, Error>!
    fileprivate var exit: Task<Void, Error>?
    init(activation: AgentActivation, purpose: AgentBackendPurpose, writers: Set<AgentWriterKey>) {
        self.activation = activation; self.purpose = purpose; self.writers = writers
    }
    func check() throws {
        try Task.checkCancellation()
        guard valid else { throw CancellationError() }
    }
}

/// Retains every start and closing resource, including those without a native file yet.
/// Only matching writers (or an explicit drain barrier) serialize; live sessions run concurrently.
@MainActor final class AgentLifecycleCoordinator {
    private(set) var owned: [UUID: AgentRuntimeLease] = [:]
    private var barrier: Set<UUID> = []
    private var accepting = true
    private var maintenance: Set<AgentID> = []
    var onQuiescent: ((AgentID) -> Void)?
    func hasWork(for agent: AgentID) -> Bool { owned.values.contains { $0.activation.agentID == agent } }
    func runningInstallations(for agent: AgentID) -> [AgentInstallationRecord] {
        Array(Dictionary(owned.values.filter { $0.activation.agentID == agent }.compactMap(\.installation).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }

    /// Closes admission before snapshot/drain; the final state change cannot suspend.
    /// Update staging never enters this barrier or interrupts existing work.
    func withMaintenance<T>(agent: AgentID, stopRunning: Bool, prepare: () throws -> Void = {},
                            mutation: () throws -> T) async throws -> T {
        guard accepting, !maintenance.contains(agent) else { throw AgentError.message("Agent maintenance is already in progress or Milk is closing.") }
        if hasWork(for: agent) && !stopRunning { throw AgentError.message("Pi is still in use. The verified update is staged for a safe boundary.") }
        maintenance.insert(agent); defer { maintenance.remove(agent) }
        try prepare()
        let leases = owned.values.filter { $0.activation.agentID == agent }
        for lease in leases { stop(lease) }
        for lease in leases { try await stopAndWait(lease) }
        try Task.checkCancellation()
        return try mutation()
    }

    func begin(activation: AgentActivation, purpose: AgentBackendPurpose,
               writers: Set<AgentWriterKey> = [], factory: @escaping @MainActor () -> any AgentOwnedResource,
               operation: @escaping @MainActor (any AgentOwnedResource, AgentRuntimeLease) async throws -> Void) -> AgentRuntimeLease {
        let predecessors = owned.values.filter { barrier.contains($0.activation.token) || !$0.writers.isDisjoint(with: writers) }
        let lease = AgentRuntimeLease(activation: activation, purpose: purpose, writers: writers)
        guard accepting, !Task.isCancelled, !maintenance.contains(activation.agentID) else {
            lease.valid = false; lease.work = Task { throw CancellationError() }
            return lease
        }
        owned[activation.token] = lease
        lease.work = Task {
            do {
                for previous in predecessors { try await self.stopAndWait(previous) }
                try lease.check()
                let resource = factory(); lease.resource = resource
                try await AgentResourceOwnership.$current.withValue(lease) { try await operation(resource, lease) }
                try lease.check(); lease.phase = .running
            } catch {
                if lease.valid { lease.phase = .failed }
                throw error
            }
        }
        return lease
    }

    func beginBackend(activation: AgentActivation, purpose: AgentBackendPurpose,
                      writers: Set<AgentWriterKey> = [], factory: @escaping @MainActor () -> any AgentBackend,
                      operation: @escaping @MainActor (any AgentBackend, AgentRuntimeLease) async throws -> Void) -> AgentRuntimeLease {
        var backend: (any AgentBackend)?
        return begin(activation: activation, purpose: purpose, writers: writers, factory: {
            let created = factory(); backend = created; return created
        }, operation: { _, lease in try await operation(backend!, lease) })
    }

    @discardableResult func stop(_ lease: AgentRuntimeLease) -> Task<Void, Error> {
        lease.valid = false
        if let exit = lease.exit { return exit }
        if lease.phase == .stopped { return Task {} }
        lease.phase = .stopping; lease.work.cancel(); lease.resource?.shutdown()
        let exit = Task {
            // A start that ignores cancellation may still create a resource. Always await it,
            // then request shutdown again before confirming that no writer remains.
            _ = await lease.work.result
            lease.resource?.shutdown()
            do {
                try await lease.resource?.shutdownAndWait()
                lease.phase = .stopped
                self.owned[lease.activation.token] = nil; self.barrier.remove(lease.activation.token)
                lease.exit = nil
                if self.accepting, !self.maintenance.contains(lease.activation.agentID), !self.hasWork(for: lease.activation.agentID) { self.onQuiescent?(lease.activation.agentID) }
            } catch {
                lease.phase = .failed; lease.exit = nil
                throw error // Retain the resource and writer keys; replacement must not pass it.
            }
        }
        lease.exit = exit
        return exit
    }
    func stopAndWait(_ lease: AgentRuntimeLease) async throws { try await stop(lease).value }
    func addWriters(_ writers: Set<AgentWriterKey>, to lease: AgentRuntimeLease) { lease.writers.formUnion(writers) }

    /// Used for workspace/configuration handoff. New starts inherit this barrier.
    func invalidateAll() {
        let leases = Array(owned.values)
        barrier.formUnion(leases.map { $0.activation.token })
        for lease in leases { stop(lease) }
    }
    func drain(writers: Set<AgentWriterKey>) async throws {
        let leases = owned.values.filter { !$0.writers.isDisjoint(with: writers) }
        for lease in leases { stop(lease) }
        for lease in leases { try await stopAndWait(lease) }
    }
    func shutdownAndWait() async -> Bool {
        accepting = false
        let leases = Array(owned.values)
        invalidateAll()
        var success = true
        // All stop requests have already been issued; resources shut down concurrently.
        for lease in leases {
            do { try await stopAndWait(lease) } catch { success = false }
        }
        return success
    }
}

struct AgentActionContext: Sendable {
    let workspace: UUID
    let session: Int
    let token: UUID
}
enum AgentActionOwnership { @TaskLocal static var current: AgentActionContext? }
enum AgentResourceOwnership { @TaskLocal static var current: AgentRuntimeLease? }
