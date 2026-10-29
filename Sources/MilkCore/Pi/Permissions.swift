import Foundation

public enum AgentMode: String, Codable, Sendable, CaseIterable { case approval, autonomous }
public enum PermissionDecision: String, Codable, Sendable { case deny, once, session }
public struct PermissionAction: Codable, Sendable, Hashable {
    public let tool: String
    public let target: String
    public init(tool: String, target: String) { self.tool = tool; self.target = target }
}
public actor PermissionService {
    private var grants: [UUID: Set<PermissionAction>] = [:]
    public init() {}
    public func allows(_ action: PermissionAction, session: UUID, mode: AgentMode) -> Bool {
        mode == .autonomous || Self.isReadOnly(action.tool) || grants[session, default: []].contains(action)
    }
    public func decide(_ decision: PermissionDecision, action: PermissionAction, session: UUID) -> Bool {
        if decision == .session { grants[session, default: []].insert(action) }
        return decision != .deny
    }
    public func endSession(_ id: UUID) { grants.removeValue(forKey: id) }
    public static func isReadOnly(_ tool: String) -> Bool { ["read", "grep", "find", "ls"].contains(tool) }
}
