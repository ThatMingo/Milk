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

    // MARK: - Fail-closed regression: audited Sandbox bypass attempts (docs/SANDBOX_SECURITY_AUDIT_2026-11-18.md)
    //
    // These assert the enforced fail-closed behaviour. They deliberately assert the opposite of the
    // compatibility behaviour that commit befaa31 introduced and ea3388f reverted: an unverifiable
    // Protected Location must deny evaluation and must prevent profile generation. They use only
    // disposable paths under `root` and always restore directory permissions before teardown.

    // Audited attempt: a Protected File Milk cannot inspect, reached through a pre-existing hard-link
    // alias that sits inside a broad readWrite Allowed Folder.
    func testFailClosedUnresolvableProtectedLocationDeniesEveryCandidateAndRefusesProfile() throws {
        let sealed = root.appendingPathComponent("sealed"), opened = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
        let secret = sealed.appendingPathComponent("secret")
        try Data("synthetic-secret".utf8).write(to: secret)
        let alias = opened.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: secret, to: alias)   // same inode, readable spelling outside the sealed directory
        var secretInfo = stat(), aliasInfo = stat()
        guard lstat(secret.path, &secretInfo) == 0, lstat(alias.path, &aliasInfo) == 0 else { throw SandboxPathError.inaccessible }
        XCTAssertEqual(SandboxFileIdentity(secretInfo), SandboxFileIdentity(aliasInfo), "The alias is the same Protected object under a second name")
        chmod(sealed.path, 0o000)
        defer { chmod(sealed.path, 0o700) }
        var c = context()
        c.configuration.protectedLocations = [.init(id: "regression:sealed-secret", url: secret)]
        c.configuration.globalAllowedFolders = [.init(id: "regression:broad", url: root, access: .readWrite)]
        // The alias has a different name, so a literal path comparison would have admitted it.
        XCTAssertNotEqual(secret.path, alias.path)
        for action in [SandboxFileAction.read, .write, .delete] {
            let decisionForAlias = decision(alias, action, c)
            XCTAssertEqual(decisionForAlias.outcome, .deny, action.rawValue)
            XCTAssertEqual(decisionForAlias.rule, .unresolvedPath, action.rawValue)
            XCTAssertEqual(decision(target, action, c).outcome, .deny, action.rawValue)
            XCTAssertEqual(decision(outside.appendingPathComponent("new"), action, c).outcome, .deny, action.rawValue)
        }
        // Profile generation must refuse rather than emit a profile whose Protected carve-out is nominal.
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots),
                             "Profile generation must refuse an unverifiable Protected Location") { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.inaccessible)
        }
    }

    // Audited attempt: a Protected Location expressed as a symlink chain longer than the resolver's
    // link ceiling, with its real target readable inside a broad readWrite Allowed Folder.
    func testFailClosedProtectedLocationBehindLongSymlinkChainOverBroadGrant() throws {
        let targetDirectory = root.appendingPathComponent("chain-target")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let token = targetDirectory.appendingPathComponent("token")
        try Data("synthetic-target".utf8).write(to: token)
        var destination = targetDirectory.path
        for index in stride(from: 44, through: 0, by: -1) {
            let hop = root.appendingPathComponent("hop\(index)")
            try FileManager.default.createSymbolicLink(atPath: hop.path, withDestinationPath: destination)
            destination = hop.path
        }
        let chainHead = root.appendingPathComponent("hop0")
        XCTAssertThrowsError(try SandboxPathResolver().resolve(chainHead)) { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.tooManyLinks)
        }
        var c = context()
        c.configuration.protectedLocations = [.init(id: "regression:chain", url: chainHead)]
        c.configuration.globalAllowedFolders = [.init(id: "regression:broad", url: root, access: .readWrite)]
        for action in [SandboxFileAction.read, .write, .delete] {
            let d = decision(token, action, c)
            XCTAssertEqual(d.outcome, .deny, action.rawValue)
            XCTAssertEqual(d.rule, .unresolvedPath, action.rawValue)
        }
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots),
                             "An unresolvable Protected Location must not compile a profile") { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.tooManyLinks)
        }
    }

    // Audited attempt: Protected Locations whose identity Milk cannot establish at all. Each one must
    // block admission instead of being guessed at; this is the fail-closed side of the compatibility
    // limitation and is expected to refuse Settings/launch rather than partially work.
    func testFailClosedUnverifiableProtectedLocationsRefuseProfileGeneration() throws {
        // A Protected Location inside a directory that cannot be searched.
        var sealedParentCase = context()
        let sealedParent = root.appendingPathComponent("sealed-parent")
        try FileManager.default.createDirectory(at: sealedParent.appendingPathComponent("inner"), withIntermediateDirectories: true)
        sealedParentCase.configuration.protectedLocations = [.init(id: "regression:sealed-inner", url: sealedParent.appendingPathComponent("inner"))]
        sealedParentCase.configuration.globalAllowedFolders = [.init(id: "regression:broad-1", url: root, access: .readWrite)]
        chmod(sealedParent.path, 0o000)
        defer { chmod(sealedParent.path, 0o700) }
        XCTAssertEqual(decision(target, .read, sealedParentCase).outcome, .deny)
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: sealedParentCase, dependencies: SandboxProfileBuilder.systemReadRoots)) { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.inaccessible)
        }
        // A Protected File whose own directory is searchable but not readable: the file contents are
        // reachable by the child, yet its identity cannot be pinned, so no profile may be built.
        var unreadableDirectoryCase = context()
        let unreadable = root.appendingPathComponent("unreadable-directory")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let tokenInside = unreadable.appendingPathComponent("token")
        try Data("synthetic-token".utf8).write(to: tokenInside)
        unreadableDirectoryCase.configuration.protectedLocations = [.init(id: "regression:unreadable-token", url: tokenInside)]
        unreadableDirectoryCase.configuration.globalAllowedFolders = [.init(id: "regression:broad-2", url: root, access: .readWrite)]
        chmod(unreadable.path, 0o111)
        defer { chmod(unreadable.path, 0o700) }
        XCTAssertEqual(decision(tokenInside, .read, unreadableDirectoryCase).outcome, .deny)
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: unreadableDirectoryCase, dependencies: SandboxProfileBuilder.systemReadRoots)) { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.inaccessible)
        }
        // A Protected Location that cannot exist because an ancestor is a regular file.
        var impossibleAncestorCase = context()
        let plainFile = root.appendingPathComponent("plain-file")
        try Data("synthetic".utf8).write(to: plainFile)
        impossibleAncestorCase.configuration.protectedLocations = [.init(id: "regression:through-file", url: plainFile.appendingPathComponent("sub"))]
        XCTAssertEqual(decision(target, .read, impossibleAncestorCase).outcome, .deny)
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: impossibleAncestorCase, dependencies: SandboxProfileBuilder.systemReadRoots)) { error in
            XCTAssertEqual(error as? SandboxPathError, SandboxPathError.notDirectory)
        }
    }

    // Audited attempt: a Protected File with a second name. Policy classifies the alias correctly, but
    // Seatbelt pathname exclusions cannot follow a pre-existing hard link, so admission must be refused.
    func testFailClosedProtectedFileWithHardLinkAliasRefusesAdmissionOverBroadGrant() throws {
        let secrets = root.appendingPathComponent("secret-dir")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let secret = secrets.appendingPathComponent("secret")
        try Data("synthetic-secret".utf8).write(to: secret)
        let alias = project.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: secret, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        var c = context()
        c.configuration.protectedLocations = [.init(id: "regression:secret", url: secret)]
        c.configuration.globalAllowedFolders = [.init(id: "regression:broad", url: root, access: .readWrite)]
        let d = decision(alias, .read, c)
        XCTAssertEqual(d.outcome, .requireProtectedLocationApproval)
        XCTAssertEqual(d.rule, .protectedLocation)
        XCTAssertEqual(d.boundaries, ["regression:secret"])
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots),
                             "A Protected file with multiple names has no safe pathname-only profile") { error in
            XCTAssertTrue(error.localizedDescription.contains("hard link"), error.localizedDescription)
        }
        // Guard against over-strictness: with the alias removed the same configuration compiles.
        try FileManager.default.removeItem(at: alias)
        XCTAssertNotNil(try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots))
    }
}
