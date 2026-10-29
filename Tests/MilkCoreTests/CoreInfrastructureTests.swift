import Foundation
import Testing
@testable import MilkCore

@Test func framingSplitUTF8AndUnicodeSeparators() throws {
    let data = Data("{\"text\":\"Ž🥛\u{2028}\u{2029}\"}\r\n{\"n\":2}\n".utf8)
    for split in 0...data.count {
        var framer = JSONLFramer()
        let a = try framer.append(Data(data.prefix(split)))
        let b = try framer.append(Data(data.dropFirst(split)))
        #expect((a + b).count == 2)
        #expect((a + b)[0]["text"].string == "Ž🥛\u{2028}\u{2029}")
        try framer.finish()
    }
}
@Test func framingRejectsMalformedOversizedAndIncompleteRecords() throws {
    var malformed = JSONLFramer()
    #expect(throws: MilkError.self) { try malformed.append(Data("{bad}\n".utf8)) }
    var oversized = JSONLFramer(maximumFrameBytes: 4)
    #expect(throws: MilkError.self) { try oversized.append(Data("12345".utf8)) }
    var unfinished = JSONLFramer(); _ = try unfinished.append(Data("{".utf8))
    #expect(throws: MilkError.self) { try unfinished.finish() }
}
private func fake(_ id: String = "first") async throws -> PiClient {
    let path = Bundle.module.url(forResource: "fake-pi", withExtension: "py", subdirectory: "Fixtures")!
    let client = PiClient()
    try await client.start(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", path.path, id]))
    return client
}
@Test func rpcCorrelatesOutOfOrderResponses() async throws {
    let client = try await fake()
    async let slow = client.request("slow", fields: ["value": .string("slow")])
    async let fast = client.request("fast", fields: ["value": .string("fast")])
    let (a,b) = try await (slow, fast)
    #expect(a["echo"].string == "slow"); #expect(b["echo"].string == "fast")
    await client.shutdown()
}
@Test func rpcCancellationAndDeadline() async throws {
    let client = try await fake()
    let request = Task { try await client.request("hang") }
    try await Task.sleep(for: .milliseconds(25)); request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    await #expect(throws: MilkError.self) { try await client.request("hang", timeout: .milliseconds(30)) }
    #expect(try await client.request("echo")["sessionId"].string == "first")
    await client.shutdown()
}
@Test func rpcExitAndMalformedFailPendingRequests() async throws {
    let exited = try await fake()
    await #expect(throws: MilkError.self) { try await exited.request("exit") }
    await exited.shutdown()
    let malformed = try await fake()
    await #expect(throws: MilkError.self) { try await malformed.request("malformed") }
    await malformed.shutdown()
}
@Test func sessionsRemainSeparate() async throws {
    let first = try await fake("one"), second = try await fake("two")
    #expect(try await first.request("get_state")["sessionId"].string == "one")
    #expect(try await second.request("get_state")["sessionId"].string == "two")
    await first.shutdown()
    #expect(try await second.request("get_state")["sessionId"].string == "two")
    await second.shutdown()
}
@Test func gitStatusPreservesPathsAndRenameDirection() throws {
    let data = Data(" M file with spaces.swift\0R  destination.swift\0source.swift\0?? line\nname.txt\0MM both.swift\0".utf8)
    let changes = try GitService.parseStatus(data)
    #expect(changes.count == 4)
    #expect(changes[0].path == "file with spaces.swift" && changes[0].unstaged && !changes[0].staged)
    #expect(changes[1].originalPath == "source.swift" && changes[1].path == "destination.swift")
    #expect(changes[2].path == "line\nname.txt")
    #expect(changes[3].staged && changes[3].unstaged)
    #expect(throws: MilkError.self) { try GitService.parseStatus(Data("R  missing-source\0".utf8)) }
}
@Test func permissionGrantsAreScopedAndRevocable() async {
    let service = PermissionService(), first = UUID(), second = UUID()
    let write = PermissionAction(tool: "write", target: "/tmp/a")
    #expect(!(await service.allows(write, session: first, mode: .approval)))
    #expect(await service.allows(write, session: first, mode: .autonomous))
    #expect(!(await service.decide(.deny, action: write, session: first)))
    #expect(await service.decide(.once, action: write, session: first))
    #expect(!(await service.allows(write, session: first, mode: .approval)))
    #expect(await service.decide(.session, action: write, session: first))
    #expect(await service.allows(write, session: first, mode: .approval))
    #expect(!(await service.allows(write, session: second, mode: .approval)))
    await service.endSession(first)
    #expect(!(await service.allows(write, session: first, mode: .approval)))
    #expect(!PermissionService.isReadOnly("custom_read_claim"))
}
@Test func extensionManifestAndCentralPermissions() async throws {
    let json = Data(#"{"id":"test","version":"1.0","protocolVersion":1,"entry":"main.js","permissions":["ui.contribute"],"contributions":[{"id":"hello","point":"status","title":"Hello"}]}"#.utf8)
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: json)
    try manifest.validate()
    let registry = ExtensionRegistry()
    try await registry.register(manifest, enabled: true)
    #expect(!(await registry.authorize(extensionID: "test", permission: .ui)))
    try await registry.register(manifest, enabled: true, granted: [.ui])
    #expect(await registry.authorize(extensionID: "test", permission: .ui))
    #expect(!(await registry.authorize(extensionID: "test", permission: .network)))
    try await registry.disable("test")
    #expect(!(await registry.authorize(extensionID: "test", permission: .ui)))
    let bad = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "main.js", with: "../main.js")
    #expect(throws: MilkError.self) { try JSONDecoder().decode(ExtensionManifest.self, from: Data(bad.utf8)).validate() }
}
@Test func workspacePersistenceAndSchemaCompatibility() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MilkStoreTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(directory: root.appendingPathComponent("Metadata"))
    var record = try WorkspaceRecord(folder: root); record.sessions = [.init(name: "Independent")]; record.selectedSession = record.sessions[0].id
    try await store.save([record]); #expect(try await store.load() == [record])
    let reopened = try WorkspaceStore(directory: root.appendingPathComponent("Metadata"))
    #expect(try await reopened.load().first?.resolve().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
    let future = try JSONEncoder().encode(WorkspaceStore.Envelope(version: 99, workspaces: [record]))
    #expect(throws: MilkError.self) { try WorkspaceStore.Envelope.decode(future) }
    let old = try JSONEncoder().encode(WorkspaceStore.Envelope(version: 0, workspaces: [record]))
    #expect(try WorkspaceStore.Envelope.decode(old).workspaces == [record])
}
@Test func githubRemoteDetection() {
    #expect(GitHubRepository.parse(remote: "git@github.com:ThatMingo/Milk.git")?.slug == "ThatMingo/Milk")
    #expect(GitHubRepository.parse(remote: "https://github.com/ThatMingo/Milk.git")?.slug == "ThatMingo/Milk")
    #expect(GitHubRepository.parse(remote: "https://example.com/owner/repo") == nil)
}
