import XCTest
@testable import Milk

final class AgentTests: XCTestCase {
    func testJSONLFramingSplitUTF8CRLFAndUnicodeSeparators() throws {
        var framer = PiJSONLFramer()
        let wire = Data("{\"type\":\"event\",\"text\":\"🥛\u{2028}milk\"}\r\n{\"type\":\"next\"}\n".utf8)
        var lines: [Data] = []
        for byte in wire { lines += try framer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        let value = try JSONDecoder().decode(JSONValue.self, from: lines[0])
        XCTAssertEqual(value["text"].string, "🥛\u{2028}milk")
        XCTAssertFalse(framer.hasPartialRecord)
        _ = try framer.append(Data("unfinished".utf8)); XCTAssertTrue(framer.hasPartialRecord)
    }
    func testMarkdownBlocksPreserveCodeAndRecognizeHeadingsListsAndQuotes() {
        let blocks = AgentMarkdownBlock.parse("# Heading\n\n- **item**\n> quote\n```swift\nlet ticks = `value`\n```\n---")
        XCTAssertEqual(blocks, [.heading(1, "Heading"), .list("•", "**item**"), .quote("quote"), .code("let ticks = `value`"), .rule])
    }
    func testRuntimeDefaultsAndConfigurationRoundTrip() throws {
        let config = AgentConfiguration()
        XCTAssertEqual(config.runtime, .bundled)
        XCTAssertEqual(try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(config)), config)
        var omlx = OMLXConfiguration(); omlx.endpoint = URL(string: "http://127.0.0.1:8000/v1")!
        XCTAssertEqual(omlx.apiBase.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(omlx.serverBase.absoluteString, "http://127.0.0.1:8000/")
        omlx.endpoint = URL(string: "http://127.0.0.1:8000/v1/")!
        XCTAssertEqual(omlx.apiBase.absoluteString, "http://127.0.0.1:8000/v1")
        omlx.endpoint = URL(string: "file:///tmp/config")!; XCTAssertThrowsError(try omlx.validated())
        omlx.endpoint = URL(string: "https://secret:password@example.com")!; XCTAssertThrowsError(try omlx.validated())
    }
    func testChangedFilesCountsAndSharedIgnoreTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("modified.txt"))
        try Data("gone\n".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("skip.log"))
        let before = try AgentFileSnapshot.capture(root: root)
        try Data("one\nthree\nfour\n".utf8).write(to: root.appendingPathComponent("modified.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try Data("new\n".utf8).write(to: root.appendingPathComponent("created.txt"))
        let changes = before.changes(to: try AgentFileSnapshot.capture(root: root))
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(changes.first { $0.path == "modified.txt" }?.added, 2)
        XCTAssertEqual(changes.first { $0.path == "modified.txt" }?.removed, 1)
        XCTAssertEqual(changes.first { $0.path == "deleted.txt" }?.kind, "Deleted")
        XCTAssertFalse(try FileTreeService().projectFiles(root: root, matching: "").contains { $0.lastPathComponent == "skip.log" })
    }

    @MainActor func testOwnedRPCShutdownGracefulTERMAndKILL() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let unrelated=Process(); unrelated.executableURL=URL(fileURLWithPath:"/bin/sleep"); unrelated.arguments=["60"]; try unrelated.run()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        for mode in ["graceful", "term", "kill"] {
            let client=PiRPCClient()
            let script="import sys,signal,time,os\n" + (mode == "kill" ? "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n":"") + "open('child.pid','w').write(str(os.getpid()))\n" + (mode == "graceful" ? "sys.stdin.read()\n":"while True: time.sleep(0.05)\n")
            try client.launch(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u","-c",script],workspace:root,environment:ProcessInfo.processInfo.environment)
            // A valid JSON numeric record does not carry an RPC response; let the child install its handler.
            try await Task.sleep(nanoseconds:300_000_000)
            let pid=try XCTUnwrap(Int32(String(contentsOf:root.appendingPathComponent("child.pid"),encoding:.utf8)))
            let start=Date(); try await client.shutdownAndWait()
            XCTAssertFalse(client.isRunning); XCTAssertLessThan(Date().timeIntervalSince(start),9)
            XCTAssertTrue(unrelated.isRunning); XCTAssertNotEqual(kill(pid,0),0)
        }
    }
    @MainActor func testRPCMalformedMessageExitDeadlinesAndTaskCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = PiRPCClient()
        defer { client.shutdown() }
        let script = "import sys,json,time\nfor line in sys.stdin:\n r=json.loads(line)\n if r['type']=='bad': print('not json',flush=True)\n elif r['type']=='hang': pass\n else: print(json.dumps({'type':'response','id':r['id'],'success':True,'data':{'ok':True}}),flush=True)\n"
        try client.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], workspace: root, environment: ProcessInfo.processInfo.environment)
        let result = try await client.request("echo"); XCTAssertTrue(result["ok"].bool)
        do { _ = try await client.request("hang", timeout: 0.1); XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("acknowledge")) }
        let task = Task { try await client.request("hang") }; task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await client.request("bad"); XCTFail("Expected protocol failure") } catch { XCTAssertTrue(error.localizedDescription.contains("malformed")) }
        let exited = PiRPCClient(); defer { exited.shutdown() }
        try exited.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import sys;sys.exit(7)"], workspace: root, environment: ProcessInfo.processInfo.environment)
        do { _ = try await exited.request("state"); XCTFail("Expected process exit") } catch { XCTAssertTrue(error.localizedDescription.contains("exited")) }
    }
}
