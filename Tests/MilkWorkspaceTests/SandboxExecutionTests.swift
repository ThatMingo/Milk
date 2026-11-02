import XCTest
import Darwin
import AppKit
@testable import Milk

final class SandboxExecutionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Execution-" + UUID().uuidString)
        for path in ["project", "outside", "profile", "cache"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SandboxPathResolver().resolve(root).canonicalURL
    }
    private func run(_ arguments: [String], executable: URL = URL(fileURLWithPath: "/bin/sh"), root: URL, profile: String?, stopAfter: Double? = nil, ready: URL? = nil) async throws -> (String, Int32) {
        let command = SandboxProfileBuilder.command(executable: executable, arguments: arguments, profile: profile)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let child = try SandboxProcess(executable: command.0, arguments: command.1, directory: root.appendingPathComponent("project"), environment: ["PATH":"/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin","HOME":root.appendingPathComponent("cache").path,"TMPDIR":root.appendingPathComponent("cache").path], input: input, output: output, errors: errors)
        try input.fileHandleForWriting.close()
        let err = Task.detached { var data = Data(); while true { let next = child.read(errors.fileHandleForReading); if next.isEmpty { break }; data.append(next) }; return data }
        let out = Task.detached { var data = Data(); while true { let next = child.read(output.fileHandleForReading); if next.isEmpty { break }; data.append(next) }; child.waitUntilExit(); return data }
        if let ready {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready.path) && child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Native fixture never became ready")
            child.terminate()
        } else if let stopAfter { try await Task.sleep(nanoseconds: UInt64(stopAfter * 1_000_000_000)); child.terminate() }
        let data = await out.value + err.value
        return (String(decoding: data, as: UTF8.self), child.terminationStatus)
    }
    private func context(_ root: URL, mode: ComposerPermissionMode = .approval) -> SandboxPolicyContext {
        var configuration = SandboxConfiguration(home: root); configuration.protectedLocations = []
        return .init(configuration: configuration, projectConfiguration: .init(), roots: .init(project: root.appendingPathComponent("project"), writableBuildRoots: [root.appendingPathComponent("cache")]), interaction: mode)
    }
    func testProductionProfileReadWriteReadOnlyOutsideAndMalformedFailClosed() async throws {
        let root = try fixture(); var c = context(root)
        let builder = SandboxProfileBuilder(), dependencies = SandboxProfileBuilder.systemReadRoots
        var profile = try builder.make(context: c, dependencies: dependencies)
        var result = try await run(["-c", "printf allowed > inside; cat inside"], root: root, profile: profile)
        XCTAssertEqual(result.1, 0, result.0); XCTAssertEqual(result.0, "allowed")
        result = try await run(["-c", "printf forbidden > \"$1\"", "sh", root.appendingPathComponent("outside/new").path], root: root, profile: profile)
        XCTAssertNotEqual(result.1, 0, result.0)
        let outside = root.appendingPathComponent("outside/data")
        try Data("outside-synthetic".utf8).write(to:outside)
        let alias = outside.path.replacingOccurrences(of:"/private/var/",with:"/var/")
        result = try await run(["-c","cat \"$1\"","sh",alias],root:root,profile:profile)
        XCTAssertNotEqual(result.1,0,"OS symlink metadata broadened outside data access")
        c.projectConfiguration.access = .readOnly; profile = try builder.make(context: c, dependencies: dependencies)
        result = try await run(["-c", "printf forbidden > inside"], root: root, profile: profile)
        XCTAssertNotEqual(result.1, 0, result.0)
        result = try await run(["-c", "printf forbidden > malformed"], root: root, profile: "(invalid-sandbox-policy)")
        XCTAssertNotEqual(result.1, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/malformed").path))
        c.configuration.enabled = false
        XCTAssertNil(try builder.make(context: c, dependencies: dependencies))
    }
    func testOwnedOrdinaryAndTermResistantCleanupDoesNotKillUnrelatedWork() async throws {
        let root = try fixture(), unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["10"]; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() }; unrelated.waitUntilExit() }
        let profile = try SandboxProfileBuilder().make(context: context(root), dependencies: SandboxProfileBuilder.systemReadRoots)
        for command in ["(sleep 2; echo leak > late) & wait", "trap '' TERM; (sleep 2; echo leak > late) & while :; do sleep 1; done"] {
            let started=Date()
            let result = try await run(["-c", command], root: root, profile: profile, stopAfter: 0.2)
            // A shell waiting for a signalled background child can exit 0. Verify cleanup, not shell exit convention.
            XCTAssertLessThan(Date().timeIntervalSince(started),1.5,result.0); XCTAssertNotEqual(result.1,-255,result.0)
            try await Task.sleep(nanoseconds:2_100_000_000)
            XCTAssertTrue(unrelated.isRunning)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/late").path))
        }
    }
    func testOwnedLeaderMovedToAnotherGroupIsStillTerminated() async throws {
        let root = try fixture(), ready = root.appendingPathComponent("project/moved-ready")
        let script = """
        import os,time
        child=os.fork()
        if child==0:
            time.sleep(0.5)
            os._exit(0)
        os.setpgid(child,child)
        os.setpgid(0,child)
        open('moved-ready','w').write('ready')
        print('moved',flush=True)
        time.sleep(20)
        """
        let profile = try SandboxProfileBuilder().make(context:context(root),dependencies:SandboxProfileBuilder.systemReadRoots)
        let result = try await run(["-c",script],executable:URL(fileURLWithPath:"/usr/bin/python3"),root:root,profile:profile,ready:ready)
        XCTAssertLessThan(result.1,0,result.0)
    }
    @MainActor private func execution(_ root: URL, mode: ComposerPermissionMode = .approval, timeout: Double = 30, configure: ((inout SandboxConfiguration) -> Void)? = nil) async throws -> (PiSandboxExecution, SandboxGrantStore, SandboxSettingsStore) {
        let suite = "Milk.Execution." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        var configuration = SandboxConfiguration(home: root); configuration.protectedLocations = []; configuration.autonomousTimeoutSeconds = timeout
        configure?(&configuration)
        defaults.set(try JSONEncoder().encode(configuration), forKey: SandboxSettingsStore.key)
        let settings = SandboxSettingsStore(defaults: defaults, home: root), grants = SandboxGrantStore()
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let activation = AgentActivation(agentID: .pi, workspace: root.appendingPathComponent("project"), sessionID: 1)
        grants.register(activation)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR": root.appendingPathComponent("profile").path,"OPENAI_API_KEY":"phase4-synthetic-provider","BASH_ENV":"/must/not/source","NODE_OPTIONS":"--require=/must/not/load"] )
        let location = try await PiLaunchResolver(runtime: runtime).resolve(.bundled, lifecycle: nil)
        let executor = try PiSandboxExecution(location: location, settings: settings, grants: grants, activation: activation, mode: mode, purpose: .conversation, inactiveProfiles: [])
        addTeardownBlock { await executor.shutdownAndWait() }
        return (executor, grants, settings)
    }
    @MainActor private func execute(_ executor: PiSandboxExecution, tool: String, args: JSONValue) async throws -> JSONValue {
        let opened = try await executor.handle(.object(["kind":.string("begin"),"tool":.string(tool),"args":args]))
        let next: JSONValue = .object(["kind":.string("next"),"operation":opened["operation"],"capability":opened["capability"]])
        while true {
            let result = try await executor.handle(next)
            if let error = result["error"].string { executor.control(opened,cancel:false); throw AgentError.message(error) }
            if result["done"].bool { executor.control(opened,cancel:false); return result["result"] }
        }
    }
    @MainActor func testRealStockWorkerResultsAndSanitizedShellDescendants() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous)
        for field in ["env","environment"] {
            do { _ = try await executor.handle(.object(["kind":.string("begin"),"tool":.string("bash"),"args":.object(["command":.string("printf unsafe"),field:.object(["MILK_PI_LOCAL_KEY":.string("synthetic-injection")])])])); XCTFail("Caller environment was admitted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("environment")) }
        }
        let written = try await execute(executor, tool: "write", args: .object(["path":.string("file.txt"),"content":.string("stock-worker")]))
        XCTAssertTrue(written["content"].text.contains("Successfully"), written.encodedString)
        let output = try await execute(executor, tool: "bash", args: .object(["command":.string("/usr/bin/python3 -c 'print(\"line\\n\" * 3000)'")]))
        let fullOutput = try XCTUnwrap(output["details"]["fullOutputPath"].string)
        XCTAssertTrue(try String(contentsOfFile:fullOutput,encoding:.utf8).contains("line"))
        let read = try await execute(executor, tool: "read", args: .object(["path":.string("file.txt")]))
        XCTAssertTrue(read["content"].text.contains("stock-worker"), read.encodedString)
        let result = try await execute(executor, tool: "bash", args: .object(["command":.string("test -z \"$MILK_PI_LOCAL_KEY\" && test -z \"$OPENAI_API_KEY\" && test -z \"$BASH_ENV\" && /usr/bin/python3 -c 'import os; assert not os.environ.get(\"MILK_PI_LOCAL_KEY\") and not os.environ.get(\"OPENAI_API_KEY\"); print(\"clean\")'")]))
        XCTAssertTrue(result["content"].text.contains("clean"), result.encodedString)
    }
    @MainActor func testRealOnceApprovalThenFutureOperationDeniedAndStaleCapabilityRejected() async throws {
        let root = try fixture(); let (executor, grants, _) = try await execution(root)
        let file = root.appendingPathComponent("outside/data"); try Data("once-real".utf8).write(to: file)
        var allow = true
        executor.event = { event in if case .approval(let request) = event { try? executor.respond(request, response: allow ? .value("Allow Once") : .cancelled) } }
        let args: JSONValue = .object(["path":.string(file.path)])
        let read = try await execute(executor, tool: "read", args: args)
        XCTAssertTrue(read["content"].text.contains("once-real"), read.encodedString); XCTAssertTrue(grants.grants.isEmpty)
        allow = false
        do { _ = try await execute(executor, tool: "read", args: args); XCTFail("Expired Once reused") } catch {}
        do { _ = try await executor.handle(.object(["kind":.string("next"),"operation":.string(UUID().uuidString),"capability":.string("forged")])); XCTFail("Stale capability accepted") } catch {}
    }
    @MainActor func testAutonomousTimeoutAndDuplicateSuppression() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous, timeout: 0.05)
        var prompts = 0
        executor.event = { if case .approval = $0 { prompts += 1 } }
        let args: JSONValue = .object(["path":.string(root.appendingPathComponent("outside/new").path),"content":.string("denied")])
        for _ in 0..<2 { do { _ = try await execute(executor, tool: "write", args: args); XCTFail("Timeout allowed") } catch { XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable"), error.localizedDescription) } }
        XCTAssertEqual(prompts,1)
    }

    @MainActor func testStockEditSearchAndImageContracts() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous)
        try Data("old\ncontext\n".utf8).write(to: root.appendingPathComponent("project/input.txt"))
        let edited = try await execute(executor, tool: "edit", args: .object(["path":.string("input.txt"),"edits":.array([.object(["oldText":.string("old"),"newText":.string("new")])])]))
        XCTAssertTrue(edited["content"].text.contains("Successfully"), edited.encodedString)
        for (tool, args, expected) in [
            ("find", JSONValue.object(["pattern":.string("*.txt")]), "input.txt"),
            ("grep", .object(["pattern":.string("new"),"context":.number(1)]), "context"),
            ("ls", .object([:]), "input.txt")
        ] {
            let result = try await execute(executor, tool: tool, args: args)
            XCTAssertTrue(result["content"].text.contains(expected), result.encodedString)
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: 16)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("project/tiny.png"))
        let image = try await execute(executor, tool: "read", args: .object(["path":.string("tiny.png")]))
        XCTAssertTrue(image["content"].array.contains { $0["type"].string == "image" }, "Image result was not preserved: " + image["content"].text)
    }
    @MainActor func testOutsideWriteSessionReuseAndExplicitRevoke() async throws {
        let root = try fixture(); let (executor, grants, _) = try await execution(root)
        var prompts = 0, allow = true
        executor.event = { event in if case .approval(let request) = event { prompts += 1; try? executor.respond(request, response: allow ? .value("Allow for Session") : .cancelled) } }
        let file = root.appendingPathComponent("outside/data")
        let args: JSONValue = .object(["path":.string(file.path),"content":.string("session-data")])
        _ = try await execute(executor, tool: "write", args: args)
        let read = try await execute(executor, tool: "read", args: .object(["path":.string(file.path)]))
        XCTAssertTrue(read["content"].text.contains("session-data")); XCTAssertEqual(prompts, 1)
        let grant = try XCTUnwrap(grants.grants.first); grants.revokeSessionGrant(grant.id); allow = false
        do { _ = try await execute(executor, tool: "read", args: .object(["path":.string(file.path)])); XCTFail("Revoked grant reused") } catch {}
        XCTAssertEqual(prompts, 2)
    }
    @MainActor func testProtectedOnlyOnceAndProjectReadOnlyRealExecution() async throws {
        let root = try fixture(), file = root.appendingPathComponent("outside/data")
        try Data("protected-synthetic".utf8).write(to: file)
        let (executor, _, _) = try await execution(root, mode: .autonomous) { c in
            c.protectedLocations = [.init(url: root.appendingPathComponent("outside"))]
            c.globalAllowedFolders = [.init(url: root, access: .readWrite)]
            c.projects[root.appendingPathComponent("project").path] = .init(access: .readOnly)
        }
        var requests: [AgentApproval] = []
        executor.event = { event in if case .approval(let request) = event { requests.append(request); try? executor.respond(request, response: .value("Allow Once")) } }
        let read = try await execute(executor, tool: "read", args: .object(["path":.string(file.path)]))
        XCTAssertTrue(read["content"].text.contains("protected-synthetic"))
        XCTAssertEqual(requests.count, 1); XCTAssertNotNil(requests[0].sandboxDeadline)
        XCTAssertTrue(requests[0].options.contains("Sandbox Settings")); XCTAssertFalse(requests[0].options.contains("Allow for Session"))
        for tool in ["write", "bash"] {
            let args: JSONValue = tool == "write" ? .object(["path":.string("denied"),"content":.string("denied")]) : .object(["command":.string("echo denied > denied")])
            do { let result = try await execute(executor, tool: tool, args: args); XCTAssertTrue(result["isError"].bool, result.encodedString) } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/denied").path))
        XCTAssertEqual(requests.count, 1, "Read Only must deny without another prompt")
    }
    @MainActor func testSessionRevokeCancelsActiveCommandAndSettingsInvalidateScope() async throws {
        let root = try fixture(); let (executor, grants, settings) = try await execution(root, mode: .autonomous)
        executor.event = { if case .approval(let request) = $0 { try? executor.respond(request, response: .value("Allow for Session")) } }
        let folders: JSONValue = .array([.object(["path":.string(root.appendingPathComponent("outside").path),"access":.string("readWrite")])])
        _ = try await execute(executor, tool: "bash", args: .object(["command":.string("printf first"),"sandboxFolders":folders]))
        let grant = try XCTUnwrap(grants.grants.first)
        let task = Task { try await self.execute(executor, tool: "bash", args: .object(["command":.string("printf ready > ready; sleep 2; printf leaked > late")])) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("project/ready").path) {
            guard Date() < deadline else { throw AgentError.message("Command did not start") }; try await Task.sleep(nanoseconds: 20_000_000)
        }
        grants.revokeSessionGrant(grant.id)
        do { _ = try await task.value; XCTFail("Revoked active execution survived") } catch {}
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/late").path))
        try settings.setEnabled(false)
        do { _ = try await executor.handle(.object(["kind":.string("begin"),"tool":.string("read"),"args":.object(["path":.string("ready")])])); XCTFail("Retired activation accepted") } catch {}
    }
    @MainActor func testNodeNpmAndPythonDescendantsStayInsideProfileAndKeyFree() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous)
        let project = root.appendingPathComponent("project")
        try Data(#"{"name":"milk-synthetic","version":"1.0.0","scripts":{"check":"node check.js"}}"#.utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("if(process.env.MILK_PI_LOCAL_KEY || process.env.OPENAI_API_KEY || process.env.NODE_OPTIONS || process.env.BASH_ENV)throw Error('credential/startup state inherited'); require('fs').writeFileSync('npm-child','clean'); console.log('npm-clean')".utf8).write(to: project.appendingPathComponent("check.js"))
        for name in ["user.npmrc", "global.npmrc"] { try Data().write(to: project.appendingPathComponent(name)) }
        let command = "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js --offline --userconfig=./user.npmrc --globalconfig=./global.npmrc run check"
        let result = try await execute(executor, tool: "bash", args: .object(["command":.string(command)]))
        XCTAssertTrue(result["content"].text.contains("npm-clean"), result.encodedString)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("npm-child"), encoding: .utf8), "clean")
        let failed = "/usr/bin/python3 -c 'open(\"" + root.appendingPathComponent("outside/forbidden").path + "\",\"w\").write(\"leak\")'"
        do { let result = try await execute(executor, tool: "bash", args: .object(["command":.string(failed)])); XCTAssertTrue(result["isError"].bool, result.encodedString) } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside/forbidden").path))
    }
    @MainActor func testSwiftAndXcodeUseTheCleanProductionWorkerEnvironment() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root,mode:.autonomous)
        try Data("print(\"swift-clean\")".utf8).write(to:root.appendingPathComponent("project/hello.swift"))
        let command = "/usr/bin/xcrun swiftc -module-cache-path \"$TMPDIR/swift-modules\" hello.swift -o hello && ./hello && /usr/bin/xcodebuild -version"
        let result = try await execute(executor,tool:"bash",args:.object(["command":.string(command)]))
        XCTAssertFalse(result["isError"].bool,result.encodedString)
        XCTAssertTrue(result["content"].text.contains("swift-clean"),result.encodedString)
        XCTAssertTrue(result["content"].text.contains("Xcode"),result.encodedString)
    }
    @MainActor func testXcodebuildActualBuildWithExplicitTemporaryItemsGrantKeepsBoundary() async throws {
        let root=try fixture(), (executor,grants,_)=try await execution(root,mode:.autonomous)
        let project=root.appendingPathComponent("project"), xcode=project.appendingPathComponent("Probe.xcodeproj")
        try FileManager.default.createDirectory(at:xcode,withIntermediateDirectories:true)
        let phase="""
        test -z "${MILK_PI_LOCAL_KEY:-}${OPENAI_API_KEY:-}" || exit 7
        printf xcode-build-clean > "$SRCROOT/xcode-result"
        if printf forbidden > '\(root.appendingPathComponent("outside/xcode-forbidden").path)'; then
          echo XCODE-SANDBOX-BYPASS; exit 9
        fi
        echo xcode-boundary-clean
        """
        let quoted=JSONValue.string(phase).encodedString
        let pbx="""
        { archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
          A00000000000000000000001 = { isa = PBXProject; buildConfigurationList = A00000000000000000000004; compatibilityVersion = "Xcode 14.0"; mainGroup = A00000000000000000000003; projectDirPath = ""; targets = (A00000000000000000000002); };
          A00000000000000000000002 = { isa = PBXAggregateTarget; buildConfigurationList = A00000000000000000000004; buildPhases = (A00000000000000000000006); dependencies = (); name = Probe; productName = Probe; };
          A00000000000000000000003 = { isa = PBXGroup; children = (); sourceTree = "<group>"; };
          A00000000000000000000004 = { isa = XCConfigurationList; buildConfigurations = (A00000000000000000000005); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
          A00000000000000000000005 = { isa = XCBuildConfiguration; buildSettings = { MACOSX_DEPLOYMENT_TARGET = 26.0; ENABLE_USER_SCRIPT_SANDBOXING = NO; }; name = Debug; };
          A00000000000000000000006 = { isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = \(quoted); };
        }; rootObject = A00000000000000000000001; }
        """
        try Data(pbx.utf8).write(to:xcode.appendingPathComponent("project.pbxproj"))
        let command="CFFIXED_USER_HOME=\"$HOME\" /usr/bin/xcodebuild -project Probe.xcodeproj -scheme Probe -configuration Debug -derivedDataPath \"$PWD/.xcode-derived\" -packageCachePath \"$PWD/.xcode-packages\" CODE_SIGNING_ALLOWED=NO CLANG_MODULE_CACHE_PATH=\"$PWD/.xcode-modules\" build"
        var result=try await execute(executor,tool:"bash",args:.object(["command":.string(command),"timeout":.number(30)]))
        if result["isError"].bool {
            // macOS item-replacement APIs use the per-user TemporaryItems directory
            // despite private HOME/TMPDIR/DerivedData. It is never admitted by default.
            // Exercise the existing explicit Once-folder flow, not a wider base profile.
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("outside/xcode-forbidden").path))
            let selected=FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems")
            try FileManager.default.createDirectory(at:selected,withIntermediateDirectories:true)
            let temporaryItems=try SandboxPathResolver().resolve(selected).canonicalURL
            var prompts=0
            executor.event={ event in if case .approval(let request)=event { prompts += 1; XCTAssertEqual(request.action,temporaryItems.path); try? executor.respond(request,response:.value("Allow Once")) } }
            result=try await execute(executor,tool:"bash",args:.object(["command":.string(command),"timeout":.number(30),"sandboxFolders":.array([.object(["path":.string(temporaryItems.path),"access":.string("readWrite")])])]))
            XCTAssertEqual(prompts,1)
        }
        guard !result["isError"].bool else { XCTFail(result.encodedString); return }
        XCTAssertTrue(result["content"].text.contains("xcode-boundary-clean"),result.encodedString)
        XCTAssertEqual(try String(contentsOf:project.appendingPathComponent("xcode-result"),encoding:.utf8),"xcode-build-clean")
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("outside/xcode-forbidden").path))
        XCTAssertTrue(grants.grants.isEmpty,"The build's Once permission must expire for future admission")
    }
    @MainActor func testDetachedSurvivorRetainsOldGrantButFreshOperationCannotReuseIt() async throws {
        let root = try fixture(), source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SandboxPhase1/lifetime_probe.c")
        let probe = root.appendingPathComponent("project/probe"), clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang"); clang.arguments = [source.path,"-o",probe.path]; try clang.run(); clang.waitUntilExit(); XCTAssertEqual(clang.terminationStatus,0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secret"), withIntermediateDirectories: true)
        var c = context(root); c.configuration.protectedLocations = [.init(url: root.appendingPathComponent("secret"))]
        let store = SandboxGrantStore(), activation = AgentActivation(agentID: .pi, workspace: root.appendingPathComponent("project"), sessionID: 1)
        store.register(activation)
        for mode in ["setsid", "double"] {
            let op = try store.beginOperation(in: activation), folder = root.appendingPathComponent("outside")
            try store.approve(SandboxPolicy().evaluate(folder, action: .write, context: c), access: .readWrite, lifetime: .once, operation: op, includesDescendants: true)
            let profile = try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots, grants: store.grants, admitting: { store.admitting($0, operation: op) })
            let marker = folder.appendingPathComponent(mode), ready = root.appendingPathComponent("project/ready-" + mode)
            let result = try await run(["spawn",mode,marker.path,ready.path,root.appendingPathComponent("secret/forbidden").path], executable: probe, root: root, profile: profile, ready: ready)
            XCTAssertTrue(result.0.contains("ready"), "mode=\(mode) result=\(result)"); store.end(op, reason: .finished)
            let next = try store.beginOperation(in: activation)
            let baseline = try SandboxProfileBuilder().make(context: c, dependencies: SandboxProfileBuilder.systemReadRoots, admitting: { store.admitting($0, operation: next) })
            let denied = try await run(["-c", "printf leak > \"$1\"", "sh", folder.appendingPathComponent("fresh").path], root: root, profile: baseline)
            XCTAssertNotEqual(denied.1,0); store.end(next,reason:.finished)
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("secret/forbidden").path))
        }
    }

    @MainActor func testUserBashProductionBridgeStreamsCancelsAndCleansBackgroundChildren() async throws {
        let root = try fixture(); let (executor, _, _) = try await execution(root, mode: .autonomous)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = PiRuntimeService(resources: project.appendingPathComponent("Runtime"), environmentOverrides: ["PI_CODING_AGENT_DIR":root.appendingPathComponent("profile").path])
        let location = try await PiLaunchResolver(runtime:runtime).resolve(.bundled,lifecycle:nil)
        var env = location.environment; env["MILK_SANDBOX_ON"] = "1"; env["MILK_PI_LOCAL_KEY"] = "synthetic-phase3-only"; env["TMPDIR"] = executor.runtimeTemporaryDirectory.path
        let client = PiRPCClient(); var tasks: [Task<Void,Never>] = [], chunks = ""
        client.onRecord = { record in
            if record["type"].string == "bash_execution_update" { chunks += record["delta"].string ?? "" }
            guard record["type"].string == "extension_ui_request" else { return }
            if record["method"].string == "input", let raw = record["title"].string?.data(using:.utf8), let request = try? JSONDecoder().decode(JSONValue.self,from:raw), request["milkSandbox"].number == 1, let id = record["id"].string {
                tasks.append(Task {
                    let response: JSONValue
                    do { response = try await executor.handle(request) }
                    catch { response = .object(["error":.string(error.localizedDescription)]) }
                    try? client.write(["type":.string("extension_ui_response"),"id":.string(id),"value":.string(response.encodedString)])
                })
            }
            if record["method"].string == "setStatus", let raw = record["statusText"].string?.data(using:.utf8), let request = try? JSONDecoder().decode(JSONValue.self,from:raw), ["milk-sandbox-cancel","milk-sandbox-finish"].contains(record["statusKey"].string ?? "") {
                executor.control(request,cancel:record["statusKey"].string == "milk-sandbox-cancel")
            }
        }
        defer { client.shutdown(); for task in tasks { task.cancel() } }
        try client.launch(executable:location.executable,arguments:["--mode","rpc","--offline","--no-session","--no-extensions","--no-mcp","--no-skills","--no-prompt-templates","-e",location.integration.path],workspace:root.appendingPathComponent("project"),environment:env,sandboxProfile:executor.runtimeProfile())
        _ = try await client.request("get_state")
        let reply = try await client.request("bash",["command":.string("test -z \"$MILK_PI_LOCAL_KEY\" && printf user-bash-clean")])
        XCTAssertEqual(reply["output"].string,"user-bash-clean"); XCTAssertEqual(reply["exitCode"].number,0)
        XCTAssertTrue(chunks.contains("user-bash-clean"), "User bash output was not streamed")
        let slow = Task { try await client.request("bash",["command":.string("printf ready > ready-bash; (sleep 2; printf leak > late-bash) & wait")]) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath:root.appendingPathComponent("project/ready-bash").path) {
            guard Date() < deadline else { throw AgentError.message("User bash never reached the executor") }; try await Task.sleep(nanoseconds:20_000_000)
        }
        _ = try await client.request("abort_bash"); let aborted = try await slow.value
        XCTAssertTrue(aborted["cancelled"].bool,aborted.encodedString)
        // Also cover a successful tool that leaves ordinary background work behind.
        _ = try await execute(executor,tool:"bash",args:.object(["command":.string("(sleep 2; echo leak > late-success) & printf finished")]))
        try await Task.sleep(nanoseconds:2_100_000_000)
        for name in ["late-bash","late-success"] { XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("project/"+name).path)) }
        try await client.shutdownAndWait()
    }
    @MainActor func testPreRPCVersionProbeIsConstrainedAndExplicitOffIsUnrestricted() async throws {
        let root = try fixture(), executable = root.appendingPathComponent("project/version-probe")
        let marker = root.appendingPathComponent("outside/version-wrote")
        try Data(("#!/bin/sh\nprintf unexpected > "+"'"+marker.path+"'"+"\nprintf 1.4.0\n").utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        var configuration = SandboxConfiguration(home:root); configuration.protectedLocations = []
        for enabled in [true,false] {
            configuration.enabled = enabled
            let authority = SandboxLaunchAuthority(configuration:configuration,isValid:true,inactiveProfiles:[])
            let result = try await SandboxLaunchAuthority.$current.withValue(authority) {
                try await PiUtilityProcess.execute(executable:executable,arguments:["--version"],environment:["PATH":"/usr/bin:/bin"],timeout:5,purpose:.versionProbe,lifecycle:nil)
            }
            XCTAssertEqual(String(decoding:result.0,as:UTF8.self),"1.4.0")
            XCTAssertEqual(FileManager.default.fileExists(atPath:marker.path),!enabled)
        }
    }

    @MainActor func testManagedStylePiVersionAndProfileOwnershipUnderProductionProfiles() async throws {
        let root = try fixture()
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/PiRuntime")
        let code = root.appendingPathComponent("managed-code")
        try FileManager.default.copyItem(at:source,to:code)
        var configuration = SandboxConfiguration(home:root); configuration.protectedLocations = []
        let authority = SandboxLaunchAuthority(configuration:configuration,isValid:true,inactiveProfiles:[])
        let version = try await SandboxLaunchAuthority.$current.withValue(authority) {
            try await PiUtilityProcess.execute(executable:code.appendingPathComponent("pi"),arguments:["--version"],environment:["HOME":root.appendingPathComponent("unavailable-home").path,"PI_CODING_AGENT_DIR":root.appendingPathComponent("profile").path,"PI_OFFLINE":"1","PATH":"/usr/bin:/bin"],timeout:5,mergeErrors:true,purpose:.versionProbe,lifecycle:nil)
        }
        XCTAssertEqual(version.1,0,String(decoding:version.0,as:UTF8.self))
        let data = root.appendingPathComponent("profile/data")
        try Data("profile-synthetic".utf8).write(to:data)
        for ownership in [SandboxProfileRoot.Ownership.existing,.managed] {
            var c = context(root,mode:.autonomous)
            c.roots.activeProfile = .init(id:"active",agentID:.pi,url:root.appendingPathComponent("profile"),ownership:ownership)
            let builder = SandboxProfileBuilder()
            let profile = try builder.make(context:c,dependencies:SandboxProfileBuilder.systemReadRoots)
            let worker = try await run(["-c","cat \"$1\"","sh",data.path],root:root,profile:profile)
            XCTAssertEqual(worker.1 == 0,ownership == .managed,worker.0)
            c.subject = .agentRuntime
            let runtime = try await run(["-c","cat \"$1\"","sh",data.path],root:root,profile:builder.make(context:c,dependencies:SandboxProfileBuilder.systemReadRoots))
            XCTAssertEqual(runtime.1,0,runtime.0)
            c.roots.activeProfile = nil
            c.roots.inactiveProfiles = [.init(id:"inactive",agentID:.pi,url:root.appendingPathComponent("profile"),ownership:ownership)]
            c.configuration.globalAllowedFolders = [.init(url:root,access:.readWrite)]
            let inactive = try await run(["-c","cat \"$1\"","sh",data.path],root:root,profile:builder.make(context:c,dependencies:SandboxProfileBuilder.systemReadRoots))
            XCTAssertNotEqual(inactive.1,0,"Inactive profile inherited a broader grant")
        }
    }

}
