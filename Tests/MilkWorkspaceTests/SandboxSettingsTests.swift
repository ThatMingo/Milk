import XCTest
@testable import Milk

final class SandboxSettingsTests: XCTestCase {
    private func fixtures() throws -> (URL, UserDefaults) {
        let name = "Milk.Sandbox.Settings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        return (try SandboxPathResolver().resolve(root).canonicalURL, defaults)
    }
    @MainActor func testDefaultsAndIndependentDurableRoundTrip() throws {
        let (root, defaults) = try fixtures()
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        XCTAssertTrue(store.configuration.enabled); XCTAssertEqual(store.configuration.autonomousTimeoutSeconds, 30)
        XCTAssertEqual(try store.projectConfiguration(for: root).access, .readWrite)
        defaults.set("approval", forKey: "unrelated-agent-permission")
        try store.setEnabled(false); try store.setTimeout(seconds: 7200)
        try store.setProjectAccess(.readOnly, project: root)
        try store.putFolder(root, access: .readWrite)
        try store.putFolder(root, access: .readOnly, project: root)
        let restored = SandboxSettingsStore(defaults: defaults, home: root)
        XCTAssertEqual(restored.configuration, store.configuration)
        XCTAssertFalse(restored.configuration.enabled)
        XCTAssertEqual(restored.configuration.autonomousTimeoutSeconds, 7200)
        XCTAssertEqual(try restored.projectConfiguration(for: root).access, .readOnly)
        XCTAssertEqual(restored.configuration.globalAllowedFolders.first?.access, .readWrite)
        XCTAssertEqual(try restored.projectConfiguration(for: root).allowedFolders.first?.access, .readOnly)
        XCTAssertEqual(defaults.string(forKey: "unrelated-agent-permission"), "approval")
        XCTAssertThrowsError(try store.setTimeout(seconds: 0)); XCTAssertThrowsError(try store.setTimeout(seconds: .infinity))
        XCTAssertEqual(store.configuration.autonomousTimeoutSeconds, 7200)
        XCTAssertTrue(try store.projectConfiguration(for: root.appendingPathComponent(".")).access == .readOnly)
    }
    @MainActor func testExplicitOffDoesNotRequireAnAvailableProject() throws {
        let (root, defaults) = try fixtures()
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        let missing = root.appendingPathComponent("unavailable-project")
        XCTAssertEqual(SandboxPolicy().evaluate(missing, action: .write, context: store.context(roots: .init(project: missing), interaction: .autonomous)).outcome, .deny)
        try store.setEnabled(false)
        XCTAssertEqual(SandboxPolicy().evaluate(missing, action: .write, context: store.context(roots: .init(project: missing), interaction: .approval)).outcome, .sandboxDisabled)
    }
    @MainActor func testFolderAndProjectAliasesCanonicalizedAndIndependent() throws {
        let (root, defaults) = try fixtures()
        let real = root.appendingPathComponent("real"), other = root.appendingPathComponent("other"), link = root.appendingPathComponent("alias")
        for url in [real, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        try store.setProjectAccess(.readOnly, project: link)
        XCTAssertEqual(try store.projectConfiguration(for: real).access, .readOnly)
        XCTAssertEqual(try store.projectConfiguration(for: other).access, .readWrite)
        try store.putFolder(link, access: .readOnly)
        XCTAssertEqual(store.configuration.globalAllowedFolders.first?.url.path, real.path)
        let id = try XCTUnwrap(store.configuration.globalAllowedFolders.first?.id)
        try store.putFolder(real, access: .readWrite, id: id)
        XCTAssertEqual(store.configuration.globalAllowedFolders.count, 1)
        try store.removeFolder(id); XCTAssertTrue(store.configuration.globalAllowedFolders.isEmpty)
        XCTAssertThrowsError(try store.putFolder(root.appendingPathComponent("missing"), access: .readWrite))
    }
    @MainActor func testProtectedEditingRemovalAndRestorePreservesCustomEntries() throws {
        let (root, defaults) = try fixtures()
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        let first = try XCTUnwrap(store.configuration.protectedLocations.first)
        let custom = root.appendingPathComponent("custom-sensitive")
        try store.putProtectedLocation(custom, id: first.id)
        try store.putProtectedLocation(root.appendingPathComponent("other-sensitive"))
        let before = store.configuration.protectedLocations
        try store.restoreRecommendedDefaults()
        XCTAssertTrue(before.allSatisfy { store.configuration.protectedLocations.contains($0) })
        XCTAssertTrue(store.configuration.protectedLocations.contains { $0.url == first.url })
        let count = store.configuration.protectedLocations.count
        try store.restoreRecommendedDefaults(); XCTAssertEqual(store.configuration.protectedLocations.count, count)
        for entry in store.configuration.protectedLocations { try store.removeProtectedLocation(entry.id) }
        XCTAssertTrue(SandboxSettingsStore(defaults: defaults, home: root).configuration.protectedLocations.isEmpty)
        var c = store.context(roots: .init(project: root), interaction: .autonomous)
        c.roots.project = root // The removed registry has no hidden hardcoded denial.
        XCTAssertEqual(SandboxPolicy().evaluate(custom, action: .read, context: c).outcome, .allow)
    }
    @MainActor func testRestoreDoesNotDuplicateEquivalentDirectoryURLs() throws {
        let (root, defaults) = try fixtures()
        let ssh = root.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        try store.putProtectedLocation(URL(fileURLWithPath: ssh.path, isDirectory: true))
        try store.restoreRecommendedDefaults()
        XCTAssertEqual(store.configuration.protectedLocations.filter { $0.url.path == ssh.path }.count, 1)
    }
    @MainActor func testMissingFieldsMigrationAndCorruptFutureSettingsFailClosed() throws {
        let (root, defaults) = try fixtures()
        defaults.set(Data("{\"enabled\":false}".utf8), forKey: SandboxSettingsStore.key)
        let migrated = SandboxSettingsStore(defaults: defaults, home: root)
        XCTAssertFalse(migrated.configuration.enabled); XCTAssertEqual(migrated.configuration.autonomousTimeoutSeconds, 30)
        XCTAssertFalse(migrated.configuration.protectedLocations.isEmpty)
        XCTAssertEqual(migrated.configuration.protectedLocations.first?.url.path, root.appendingPathComponent(".ssh").path)
        for data in [Data("not-json".utf8), Data("{\"version\":99,\"enabled\":false}".utf8)] {
            defaults.set(data, forKey: SandboxSettingsStore.key)
            let invalid = SandboxSettingsStore(defaults: defaults, home: root)
            XCTAssertFalse(invalid.isValid); XCTAssertNotNil(invalid.problem)
            let d = SandboxPolicy().evaluate(root, action: .read, context: invalid.context(roots: .init(project: root), interaction: .autonomous))
            XCTAssertEqual(d.outcome, .deny); XCTAssertEqual(d.rule, .invalidConfiguration)
            XCTAssertEqual(defaults.data(forKey: SandboxSettingsStore.key), data, "Loading must not overwrite corrupt/future state")
        }
    }
    @MainActor func testNoTransientAuthorityInPersistenceAndNonpersistingStore() throws {
        let (root, defaults) = try fixtures()
        let store = SandboxSettingsStore(defaults: defaults, home: root)
        try store.setTimeout(seconds: 90)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: SandboxSettingsStore.key))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "enabled", "globalAllowedFolders", "protectedLocations", "autonomousTimeoutSeconds", "projects"])
        let temporary = SandboxSettingsStore(defaults: defaults, persist: false, home: root)
        try temporary.setEnabled(false)
        XCTAssertFalse(temporary.configuration.enabled)
        XCTAssertTrue(SandboxSettingsStore(defaults: defaults, home: root).configuration.enabled)
    }
}
