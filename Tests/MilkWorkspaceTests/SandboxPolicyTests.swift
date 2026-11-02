import XCTest
@testable import Milk

final class SandboxPolicyTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project") }
    private var outside: URL { root.appendingPathComponent("outside") }
    private var target: URL { project.appendingPathComponent("sub/file") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-SandboxPolicy-" + UUID().uuidString).resolvingSymlinksInPath()
        for name in ["project/sub", "outside", "managed", "existing", "cache"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        root = try SandboxPathResolver().resolve(root).canonicalURL
        try Data("synthetic".utf8).write(to: target)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func context(_ mode: ComposerPermissionMode = .autonomous) -> SandboxPolicyContext {
        var c = SandboxConfiguration(home: root); c.protectedLocations = []
        return .init(configuration: c, projectConfiguration: .init(), roots: .init(project: project), interaction: mode)
    }
    private func decision(_ url: URL, _ action: SandboxFileAction, _ c: SandboxPolicyContext) -> SandboxPolicyDecision {
        SandboxPolicy().evaluate(url, action: action, context: c)
    }
    func testDefaultsDisabledAndInteractionModesIndependent() {
        XCTAssertTrue(SandboxConfiguration(home: root).enabled)
        XCTAssertEqual(SandboxProjectConfiguration().access, .readWrite)
        XCTAssertEqual(SandboxConfiguration(home: root).autonomousTimeoutSeconds, 30)
        for mode in ComposerPermissionMode.allCases {
            var c = context(mode)
            XCTAssertEqual(decision(target, .write, c).outcome, .allow)
            c.configuration.enabled = false
            let d = decision(target, .write, c)
            XCTAssertEqual(d.outcome, .sandboxDisabled); XCTAssertEqual(d.rule, .disabled)
            XCTAssertEqual(c.interaction, mode)
        }
    }
    func testSevenLevelPrecedenceTable() {
        struct Row { let name: String; let setup: (inout SandboxPolicyContext) -> Void; let rule: SandboxPolicyRule; let outcome: SandboxPolicyOutcome }
        let folder = SandboxFolderGrant(url: project, access: .readWrite)
        let inactive = SandboxProfileRoot(id: "inactive", agentID: .pi, url: project, ownership: .existing)
        let managed = SandboxProfileRoot(id: "active", agentID: .pi, url: project, ownership: .managed)
        let rows: [Row] = [
            .init(name: "Protected beats inactive and broad folders", setup: { c in c.configuration.protectedLocations = [.init(url: self.project)]; c.roots.inactiveProfiles = [inactive]; c.configuration.globalAllowedFolders = [folder] }, rule: .protectedLocation, outcome: .requireProtectedLocationApproval),
            .init(name: "Inactive beats project RO and broad folders", setup: { c in c.roots.inactiveProfiles = [inactive]; c.projectConfiguration.access = .readOnly; c.configuration.globalAllowedFolders = [folder] }, rule: .inactiveProfile, outcome: .requireSandboxApproval),
            .init(name: "Project RO beats writable folder and active profile", setup: { c in c.projectConfiguration.access = .readOnly; c.configuration.globalAllowedFolders = [folder]; c.roots.activeProfile = managed }, rule: .projectReadOnly, outcome: .deny),
            .init(name: "Folder RO beats managed active profile and normal project", setup: { c in c.configuration.globalAllowedFolders = [.init(url: self.project, access: .readOnly)]; c.roots.activeProfile = managed }, rule: .allowedFolder, outcome: .requireSandboxApproval),
            .init(name: "Active profile before normal project", setup: { $0.roots.activeProfile = managed }, rule: .activeProfile, outcome: .allow),
            .init(name: "Normal project before outside default", setup: { _ in }, rule: .project, outcome: .allow),
            .init(name: "Outside write uses default", setup: { $0.roots.project = self.outside }, rule: .outsideProject, outcome: .requireSandboxApproval)
        ]
        for row in rows {
            var c = context(); row.setup(&c)
            let d = decision(target, .write, c)
            XCTAssertEqual(d.rule, row.rule, row.name); XCTAssertEqual(d.outcome, row.outcome, row.name)
        }
    }
    func testProjectReadOnlyAndOutsideReadWriteDeleteMatrix() {
        for mode in ComposerPermissionMode.allCases {
            var c = context(mode); c.projectConfiguration.access = .readOnly
            for action in [SandboxFileAction.read, .write, .delete] {
                XCTAssertEqual(decision(target, action, c).outcome, action == .read ? .allow : .deny)
                let expected: SandboxPolicyOutcome = mode == .autonomous && action == .read ? .allow : .requireSandboxApproval
                XCTAssertEqual(decision(outside.appendingPathComponent("new"), action, c).outcome, expected)
            }
        }
    }
    func testAllowedFolderROAndRWGlobalAndProject() {
        for access in SandboxFolderAccess.allCases {
            for projectScoped in [false, true] {
                for mode in ComposerPermissionMode.allCases {
                    var c = context(mode)
                    let folder = SandboxFolderGrant(url: outside, access: access)
                    if projectScoped { c.projectConfiguration.allowedFolders = [folder] } else { c.configuration.globalAllowedFolders = [folder] }
                    for action in [SandboxFileAction.read, .write, .delete] {
                        let d = decision(outside.appendingPathComponent("new"), action, c)
                        XCTAssertEqual(d.rule, .allowedFolder)
                        XCTAssertEqual(d.outcome, access.permits(action) ? .allow : .requireSandboxApproval)
                    }
                }
            }
        }
    }
    func testProtectedLocationClassificationAllActionsAndModes() {
        for mode in ComposerPermissionMode.allCases {
            var c = context(mode); c.configuration.protectedLocations = [.init(url: outside)]
            c.configuration.globalAllowedFolders = [.init(url: root, access: .readWrite)]
            for action in [SandboxFileAction.read, .write, .delete] {
                let d = decision(outside.appendingPathComponent("new"), action, c)
                XCTAssertEqual(d.outcome, .requireProtectedLocationApproval); XCTAssertEqual(d.rule, .protectedLocation)
            }
        }
    }
    func testManagedExistingRuntimeAndExecutorProfiles() {
        let managed = root.appendingPathComponent("managed"), existing = root.appendingPathComponent("existing")
        for ownership in [SandboxProfileRoot.Ownership.managed, .existing] {
            for subject in [SandboxSubject.agentRuntime, .executor, .extensionWorker] {
                var c = context(); c.subject = subject
                let activeURL = ownership == .managed ? managed : existing, inactiveURL = ownership == .managed ? existing : managed
                c.roots.activeProfile = .init(id: "active", agentID: .pi, url: activeURL, ownership: ownership)
                c.roots.inactiveProfiles = [.init(id: "inactive", agentID: .pi, url: inactiveURL, ownership: ownership == .managed ? .existing : .managed)]
                for action in [SandboxFileAction.read, .write] {
                    XCTAssertEqual(decision(activeURL.appendingPathComponent("new"), action, c).outcome,
                                   subject == .agentRuntime || ownership == .managed ? .allow : .requireSandboxApproval)
                    XCTAssertEqual(decision(inactiveURL.appendingPathComponent("new"), action, c).outcome, .requireSandboxApproval)
                }
                c.configuration.globalAllowedFolders = [.init(url: root, access: .readWrite)]
                XCTAssertEqual(decision(inactiveURL, .read, c).rule, .inactiveProfile)
            }
        }
    }
    func testBuildRootsDoNotBypassProtectedOrProjectReadOnly() {
        var c = context(); let cache = root.appendingPathComponent("cache")
        c.roots.writableBuildRoots = [cache, project]; c.projectConfiguration.access = .readOnly
        XCTAssertEqual(decision(cache.appendingPathComponent("new"), .write, c).outcome, .allow)
        XCTAssertEqual(decision(target, .write, c).rule, .projectReadOnly)
        c.configuration.protectedLocations = [.init(url: cache)]
        XCTAssertEqual(decision(cache, .write, c).outcome, .requireProtectedLocationApproval)
    }
    func testAmbiguousOverlapFailsClosed() {
        var c = context()
        c.configuration.globalAllowedFolders = [.init(url: root, access: .readOnly)]
        c.projectConfiguration.allowedFolders = [.init(url: project, access: .readWrite)]
        XCTAssertEqual(decision(target, .read, c).outcome, .deny)
        c = context(); c.roots.activeProfile = .init(id: "active", agentID: .pi, url: project, ownership: .managed)
        c.roots.inactiveProfiles = [.init(id: "inactive", agentID: .pi, url: root, ownership: .existing)]
        XCTAssertEqual(decision(target, .write, c).rule, .ambiguousRoots)
        c = context(); c.roots.inactiveProfiles = [.init(id: "one", agentID: .pi, url: root, ownership: .managed), .init(id: "two", agentID: .pi, url: project, ownership: .existing)]
        XCTAssertEqual(decision(target, .read, c).outcome, .deny)
    }
    func testSymlinkEscapeAndNonexistentDescendantsThroughExistingAncestor() throws {
        let alias = project.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let request = alias.appendingPathComponent("not-created/child")
        let path = try SandboxPathResolver().resolve(request)
        XCTAssertEqual(path.canonicalURL, outside.appendingPathComponent("not-created/child"))
        XCTAssertEqual(path.existingAncestor, outside); XCTAssertEqual(path.missingComponents, ["not-created", "child"])
        XCTAssertTrue(path.revalidated())
        XCTAssertEqual(decision(request, .write, context()).rule, .outsideProject)
        var c = context(); c.configuration.protectedLocations = [.init(url: outside)]
        XCTAssertEqual(decision(request, .read, c).outcome, .requireProtectedLocationApproval)
        let boundary = root.appendingPathComponent("project-other")
        XCTAssertEqual(decision(boundary, .write, context()).rule, .outsideProject)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        XCTAssertFalse(path.revalidated(), "A snapshot cannot survive alias retargeting")
    }
    func testSymlinkDotDotDanglingCycleAndFileAncestor() throws {
        let link = project.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let path = try SandboxPathResolver().resolve(URL(fileURLWithPath: link.path + "/../project/sub/file"))
        XCTAssertEqual(path.canonicalURL, target)
        let cycle = project.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(atPath: cycle.path, withDestinationPath: "cycle")
        XCTAssertEqual(decision(cycle, .read, context()).outcome, .deny)
        XCTAssertEqual(decision(URL(fileURLWithPath: target.path + "/child"), .read, context()).outcome, .deny)
        XCTAssertEqual(decision(URL(fileURLWithPath: outside.path + "/missing/../file"), .read, context()).outcome, .deny)
        let dangling = project.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        XCTAssertEqual(decision(dangling, .write, context()).rule, .outsideProject)
        let selfLink = project.appendingPathComponent("self")
        try FileManager.default.createSymbolicLink(atPath: selfLink.path, withDestinationPath: ".")
        XCTAssertTrue(try SandboxPathResolver().resolve(selfLink).isDirectory)
    }
    func testHardLinkProtectedFileAndCaseAlias() throws {
        let secret = outside.appendingPathComponent("secret"), alias = project.appendingPathComponent("alias")
        try Data("synthetic".utf8).write(to: secret)
        try FileManager.default.linkItem(at: secret, to: alias)
        var c = context(); c.configuration.protectedLocations = [.init(url: secret)]
        XCTAssertEqual(decision(alias, .read, c).outcome, .requireProtectedLocationApproval)
        let upper = URL(fileURLWithPath: outside.path.uppercased() + "/secret")
        // On a case-sensitive volume this spelling is a different missing path.
        if FileManager.default.fileExists(atPath: upper.path) {
            XCTAssertEqual(decision(upper, .read, c).outcome, .requireProtectedLocationApproval)
        }
    }
    func testInvalidConfigurationRemotePathAndGitIsNotAGrant() {
        var c = context(); c.configurationIsValid = false
        XCTAssertEqual(decision(target, .read, c).outcome, .deny)
        c = context()
        XCTAssertEqual(decision(URL(string: "https://example.invalid/file")!, .read, c).outcome, .deny)
        // There is deliberately no Git escalation capability in this filesystem policy API.
        XCTAssertFalse(SandboxEnvironmentDomain.milkExecutor.mayReceiveConfiguredProviderCredential)
        XCTAssertTrue(SandboxEnvironmentDomain.milkExtensionWorker.requiresIndependentSanitizedEnvironment)
        XCTAssertTrue(SandboxEnvironmentDomain.agentRuntime.mayReceiveConfiguredProviderCredential)
    }
}
