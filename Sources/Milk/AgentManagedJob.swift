import Foundation
import Combine

struct AgentManagedJobRequest: Equatable {
    enum Purpose: String { case preview, watcher, background }
    var command: String
    var directory: URL
    var purpose: Purpose
    var folders: [(URL,SandboxFolderAccess)] = []
    static func == (a: Self, b: Self) -> Bool { a.command == b.command && a.directory == b.directory && a.purpose == b.purpose && a.folders.map { $0.0.path+":"+$0.1.rawValue } == b.folders.map { $0.0.path+":"+$0.1.rawValue } }
}
/// Live host receipt, never decoded from agent JSON or adopted from a PID/port.
@MainActor final class AgentManagedJob: ObservableObject, Identifiable {
    enum State: String { case starting, running, stopping, stopped, failed }
    let id = UUID()
    let activation: AgentActivation
    let request: AgentManagedJobRequest
    let owner: String?
    let environmentDomain = SandboxEnvironmentDomain.milkExecutor
    @Published var state: State = .starting
    @Published var output = ""
    private(set) var generation = UUID()
    var scope: SandboxOperationScope?
    var profile: String?
    var usedGrants: Set<UUID> = []
    var process: SandboxProcess?
    var completion: Task<Void,Never>?
    var stopAction: (() async -> Void)?
    var restartAction: (() async throws -> Void)?
    init(activation: AgentActivation, request: AgentManagedJobRequest, owner: String?) { self.activation=activation; self.request=request; self.owner=owner }
    func nextGeneration() -> UUID { generation=UUID(); return generation }
    func stop() async { await stopAction?() }
    func restart() async throws { guard let restartAction else { throw CancellationError() }; try await restartAction() }
}
