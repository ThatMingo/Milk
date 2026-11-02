import XCTest
@testable import Milk

@MainActor private final class SandboxLeaseResource: AgentOwnedResource {
    var failExit = false
    func shutdown() {}
    func shutdownAndWait() async throws { if failExit { throw CancellationError() } }
}
final class SandboxGrantTests: XCTestCase {
    @MainActor private func fixture() throws -> (SandboxPolicyContext, AgentActivation, SandboxGrantStore, SandboxOperationScope, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-SandboxGrants-" + UUID().uuidString).resolvingSymlinksInPath()
        for name in ["project", "outside"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var config = SandboxConfiguration(home: root); config.protectedLocations = []
        let c = SandboxPolicyContext(configuration: config, projectConfiguration: .init(), roots: .init(project: root.appendingPathComponent("project")), interaction: .approval)
        let activation = AgentActivation(agentID: .pi, workspace: c.roots.project, sessionID: 1)
        let store = SandboxGrantStore(); store.register(activation)
        return (c, activation, store, try store.beginOperation(in: activation), root.appendingPathComponent("outside"))
    }
    @MainActor func testOnceBoundToExactlyOneOperationAndAllEndReasons() throws {
        for reason in [SandboxOperationEnd.finished, .cancelled, .timedOut, .ended] {
            let (c, activation, store, operation, target) = try fixture()
            let d = SandboxPolicy().evaluate(target, action: .write, context: c)
            try store.approve(d, access: .readWrite, lifetime: .once, operation: operation, includesDescendants: true)
            XCTAssertEqual(store.admitting(d, operation: operation).outcome, .allow)
            let other = try store.beginOperation(in: activation)
            XCTAssertEqual(store.admitting(d, operation: other).outcome, .requireSandboxApproval)
            store.end(operation, reason: reason)
            XCTAssertTrue(store.grants.isEmpty)
            XCTAssertEqual(store.admitting(d, operation: operation).rule, .staleOwnership)
            XCTAssertThrowsError(try store.approve(d, access: .readWrite, lifetime: .once, operation: operation))
            let next = try store.beginOperation(in: activation)
            XCTAssertEqual(store.admitting(d, operation: next).outcome, .requireSandboxApproval)
        }
    }
    @MainActor func testSessionReuseExplicitRevokeAndIsolationFromOtherRuntime() throws {
        let (c, activation, store, operation, target) = try fixture()
        let d = SandboxPolicy().evaluate(target, action: .write, context: c)
        let grant = try store.approve(d, access: .readWrite, lifetime: .session, operation: operation, includesDescendants: true)
        store.end(operation, reason: .finished)
        let next = try store.beginOperation(in: activation)
        XCTAssertEqual(store.admitting(d, operation: next).outcome, .allow)
        let other = AgentActivation(agentID: .init(rawValue: "future-agent"), workspace: activation.workspace, sessionID: activation.sessionID)
        store.register(other); let otherOp = try store.beginOperation(in: other)
        XCTAssertEqual(store.admitting(d, operation: otherOp).outcome, .requireSandboxApproval)
        store.revokeSessionGrant(grant.id)
        XCTAssertEqual(store.admitting(d, operation: next).outcome, .requireSandboxApproval)
        XCTAssertTrue(store.grants.isEmpty)
    }
    @MainActor func testRuntimeInvalidationRestartSavedChatReopenAndShutdown() throws {
        let (c, activation, store, operation, target) = try fixture()
        let d = SandboxPolicy().evaluate(target, action: .write, context: c)
        try store.approve(d, access: .readWrite, lifetime: .session, operation: operation)
        store.invalidate(activation)
        XCTAssertTrue(store.grants.isEmpty); XCTAssertThrowsError(try store.beginOperation(in: activation))
        XCTAssertFalse(store.register(activation), "An invalidated activation cannot be resurrected")
        let reopened = AgentActivation(agentID: activation.agentID, workspace: activation.workspace, sessionID: activation.sessionID)
        store.register(reopened)
        let next = try store.beginOperation(in: reopened)
        XCTAssertEqual(store.admitting(d, operation: next).outcome, .requireSandboxApproval)
        let freshMilk = SandboxGrantStore(); freshMilk.register(reopened)
        XCTAssertTrue(freshMilk.grants.isEmpty)
        try store.approve(d, access: .readWrite, lifetime: .session, operation: next)
        store.shutdown()
        XCTAssertTrue(store.grants.isEmpty); XCTAssertThrowsError(try store.beginOperation(in: reopened))
        store.register(reopened); XCTAssertThrowsError(try store.beginOperation(in: reopened))
    }
    @MainActor func testGrantCannotWidenFixedRuntimeOrDifferentEnvironmentDomain() throws {
        let (c, _, store, operation, target) = try fixture()
        let d = SandboxPolicy().evaluate(target, action: .write, context: c)
        try store.approve(d, access: .readWrite, lifetime: .once, operation: operation)
        var runtime = c; runtime.subject = .agentRuntime
        let runtimeDecision = SandboxPolicy().evaluate(target, action: .write, context: runtime)
        XCTAssertEqual(store.admitting(runtimeDecision, operation: operation).outcome, .requireSandboxApproval)
        XCTAssertThrowsError(try store.approve(runtimeDecision, access: .readWrite, lifetime: .once, operation: operation))
        runtime.subject = .extensionWorker
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(target, action: .write, context: runtime), operation: operation).outcome, .requireSandboxApproval)
    }
    @MainActor func testProtectedOnceOnlyAndNewHigherPriorityRulesCannotReuseGrant() throws {
        let (c, _, store, operation, target) = try fixture()
        let original = SandboxPolicy().evaluate(target, action: .write, context: c)
        try store.approve(original, access: .readWrite, lifetime: .session, operation: operation, includesDescendants: true)
        var protected = c; protected.configuration.protectedLocations = [.init(url: target)]
        let p = SandboxPolicy().evaluate(target, action: .write, context: protected)
        XCTAssertEqual(store.admitting(p, operation: operation).outcome, .requireProtectedLocationApproval)
        XCTAssertThrowsError(try store.approve(p, access: .readWrite, lifetime: .session, operation: operation))
        let once = try store.approve(p, access: .readWrite, lifetime: .once, operation: operation)
        XCTAssertEqual(store.admitting(p, operation: operation).outcome, .allow)
        store.revokeSessionGrant(once.id); XCTAssertTrue(store.grants.contains { $0.id == once.id })
        var inactive = c
        inactive.roots.inactiveProfiles = [.init(id: "inactive", agentID: .pi, url: target, ownership: .existing)]
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(target, action: .write, context: inactive), operation: operation).outcome, .requireSandboxApproval)
        var readOnly = c; readOnly.roots.project = target; readOnly.projectConfiguration.access = .readOnly
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(target, action: .write, context: readOnly), operation: operation).outcome, .deny)
    }
    @MainActor func testReadOnlyGrantAndExactVersusFolderScope() throws {
        let (c, _, store, operation, target) = try fixture()
        let d = SandboxPolicy().evaluate(target, action: .read, context: c)
        try store.approve(d, access: .readOnly, lifetime: .once, operation: operation)
        let child = target.appendingPathComponent("new")
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(child, action: .read, context: c), operation: operation).outcome, .requireSandboxApproval)
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(target, action: .write, context: c), operation: operation).outcome, .requireSandboxApproval)
        try store.approve(d, access: .readOnly, lifetime: .once, operation: operation, includesDescendants: true)
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(child, action: .read, context: c), operation: operation).outcome, .allow)
    }
    @MainActor func testReplacedGrantRootCannotAuthorizeFreshPathOrCachedDecision() throws {
        let (c, _, store, operation, target) = try fixture()
        let d = SandboxPolicy().evaluate(target, action: .write, context: c)
        try store.approve(d, access: .readWrite, lifetime: .session, operation: operation, includesDescendants: true)
        try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertEqual(store.admitting(d, operation: operation).outcome, .deny)
        XCTAssertEqual(store.admitting(SandboxPolicy().evaluate(target, action: .write, context: c), operation: operation).outcome, .requireSandboxApproval)
    }
    @MainActor func testLifecycleInvalidatesBeforeFailedDrainAndRejectsClosedAdmission() async throws {
        let (c, activation, _, _, target) = try fixture()
        let owner = AgentLifecycleCoordinator(), resource = SandboxLeaseResource()
        let lease = owner.begin(activation: activation, purpose: .conversation, factory: { resource }) { _, _ in }
        try await lease.work.value
        let operation = try owner.sandboxGrants.beginOperation(in: activation)
        let d = SandboxPolicy().evaluate(target, action: .write, context: c)
        try owner.sandboxGrants.approve(d, access: .readWrite, lifetime: .session, operation: operation)
        resource.failExit = true
        let drain = owner.stop(lease)
        XCTAssertTrue(owner.sandboxGrants.grants.isEmpty, "Invalidation must not wait for process cleanup")
        XCTAssertEqual(owner.sandboxGrants.admitting(d, operation: operation).rule, .staleOwnership)
        do { try await drain.value; XCTFail("Fixture drain must fail") } catch {}
        resource.failExit = false; try await owner.stopAndWait(lease)
        let closed = await owner.shutdownAndWait(); XCTAssertTrue(closed)
        let rejected = AgentActivation(agentID: .pi, workspace: activation.workspace, sessionID: 1)
        let deniedLease = owner.begin(activation: rejected, purpose: .conversation, factory: { resource }) { _, _ in }
        XCTAssertFalse(deniedLease.valid)
        XCTAssertThrowsError(try owner.sandboxGrants.beginOperation(in: rejected))
    }
    @MainActor func testLifecycleStartFailureInvalidatesScope() async throws {
        let (_, activation, _, _, _) = try fixture()
        let owner = AgentLifecycleCoordinator(), resource = SandboxLeaseResource()
        let lease = owner.begin(activation: activation, purpose: .conversation, factory: { resource }) { _, _ in throw CancellationError() }
        do { try await lease.work.value; XCTFail("Expected start failure") } catch {}
        XCTAssertThrowsError(try owner.sandboxGrants.beginOperation(in: activation))
        try await owner.stopAndWait(lease)
    }
}
