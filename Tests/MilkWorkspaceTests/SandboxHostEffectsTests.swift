import XCTest
import Foundation
import Darwin
import Combine
import MilkExtensionKit
import MilkExtensionHost
@testable import Milk

final class SandboxHostEffectsTests: XCTestCase {
    let fm=FileManager.default
    var project: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func temporary() throws -> URL {
        let url=fm.temporaryDirectory.appendingPathComponent("Milk-Host-Effects-"+UUID().uuidString)
        try fm.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url.resolvingSymlinksInPath()
    }
    @discardableResult func git(_ args: [String], _ root: URL) throws -> String {
        let p=Process(), output=Pipe(); p.executableURL=URL(fileURLWithPath:"/usr/bin/git"); p.arguments=args; p.currentDirectoryURL=root
        p.environment=["PATH":"/usr/bin:/bin","HOME":root.deletingLastPathComponent().appendingPathComponent("home").path,"GIT_CONFIG_NOSYSTEM":"1","GIT_TERMINAL_PROMPT":"0"]
        p.standardOutput=output; p.standardError=output; try p.run()
        let data=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); let text=String(decoding:data,as:UTF8.self)
        guard p.terminationStatus == 0 else { throw AgentError.message(text) }; return text
    }
    func repository(_ base: URL) throws -> URL {
        let root=base.appendingPathComponent("repo"); try fm.createDirectory(at:root,withIntermediateDirectories:true)
        try fm.createDirectory(at:base.appendingPathComponent("home"),withIntermediateDirectories:true)
        try git(["init","-b","main"],root); try git(["config","user.name","Milk Test"],root); try git(["config","user.email","synthetic@example.invalid"],root)
        try Data("one".utf8).write(to:root.appendingPathComponent("one")); try git(["add","one"],root); try git(["commit","-m","initial"],root); return root
    }
    @MainActor func effects(_ base: URL, root: URL, mode: ComposerPermissionMode = .autonomous, configure: ((inout SandboxPolicyContext) -> Void)? = nil) throws -> (SandboxHostEffects,SandboxGrantStore) {
        let activation=AgentActivation(agentID:.pi,workspace:root,sessionID:9), grants=SandboxGrantStore(), approvals=SandboxApprovalCenter()
        grants.register(activation)
        let cache=base.appendingPathComponent("cache"); try fm.createDirectory(at:cache,withIntermediateDirectories:true)
        var config=SandboxConfiguration(home:base); config.protectedLocations=[]
        var policy=SandboxPolicyContext(configuration:config,projectConfiguration:.init(),roots:.init(project:root,writableBuildRoots:[cache]),interaction:mode)
        configure?(&policy)
        let effects=try SandboxHostEffects(activation:activation,grants:grants,approvals:approvals,cache:cache,gitHome:base.appendingPathComponent("home"),context:{ policy },dependencies:{ SandboxProfileBuilder.systemReadRoots },mode:{ mode },timeout:{ 10 })
        addTeardownBlock { await effects.shutdownAndWait() }; return (effects,grants)
    }
    @MainActor func callGit(_ argv: [String], _ effects: SandboxHostEffects) async throws -> SandboxHostEffects.Output {
        let scope=try effects.grants.beginOperation(in:effects.activation); defer { effects.grants.end(scope,reason:.finished) }
        return try await effects.git(arguments:argv,scope:scope)
    }
    func testStructuredGitRejectsShellAndExecutionOverrides() throws {
        for args in [["sh","-c","git add ."],["-C","/tmp","status"],["-c","core.hooksPath=/tmp","commit"],["commit","--exec=sh"],["add","../outside"],["add",":(top)outside"],["push","ext::sh -c evil"],["apply","--unsafe-paths","--cached","-"],["apply","--cached","/tmp/patch"],["status; touch /tmp/x"],["branch","--list","-D","main"],["checkout","main && sh"]] {
            XCTAssertThrowsError(try SandboxGitCommand.recognize(args),args.joined(separator:" "))
        }
        for args in [["status","--short"],["diff","--cached"],["add","--","one"],["restore","--staged","one"],["commit","--amend","--no-edit"],["switch","-c","topic"],["checkout","main"],["branch","-D","topic"],["merge","--ff-only","topic"],["reset","--hard","HEAD"],["fetch","origin"],["pull","--ff-only","origin","main"],["push","origin","main:main"]] { XCTAssertNoThrow(try SandboxGitCommand.recognize(args)) }
    }
    @MainActor func testRealGitWorkflowHooksEditorDiffHelperAndFollowingShellContainment() async throws {
        let base=try temporary(), root=try repository(base), marker=base.appendingPathComponent("hook")
        let hook=root.appendingPathComponent(".git/hooks/pre-commit")
        try Data(("#!/bin/sh\nprintf hook > '"+marker.path+"'\n").utf8).write(to:hook); try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        let editor=base.appendingPathComponent("editor.sh"), editorMarker=base.appendingPathComponent("edited")
        try Data(("#!/bin/sh\nprintf 'editor commit\\n' > \"$1\"\nprintf edited > '"+editorMarker.path+"'\n").utf8).write(to:editor); try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:editor.path)
        let helper=base.appendingPathComponent("diff.sh")
        try Data("#!/bin/sh\nprintf 'real-helper\\n'\n".utf8).write(to:helper); try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        try git(["config","core.editor",editor.path],root); try git(["config","diff.external",helper.path],root)
        let (effects,grants)=try effects(base,root:root)
        try Data("two".utf8).write(to:root.appendingPathComponent("one"))
        let added=try await callGit(["add","--","one"],effects); XCTAssertEqual(added.code,0,added.text)
        let committed=try await callGit(["commit"],effects); XCTAssertEqual(committed.code,0,committed.text)
        XCTAssertTrue(fm.fileExists(atPath:marker.path)); XCTAssertTrue(fm.fileExists(atPath:editorMarker.path))
        for argv in [["commit","--amend","--no-edit"],["switch","-c","topic"],["checkout","main"],["branch","-D","topic"],["status","--short"]] { let result=try await callGit(argv,effects); XCTAssertEqual(result.code,0,result.text) }
        try Data("three".utf8).write(to:root.appendingPathComponent("one"))
        let diff=try await callGit(["diff","--ext-diff"],effects); XCTAssertTrue(diff.text.contains("real-helper"),diff.text)
        let scope=try grants.beginOperation(in:effects.activation), profile=try effects.profile(scope)
        let denied=try await effects.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf forbidden > .git/forbidden"],directory:root,environment:SandboxEnvironment.execution(home:effects.cache,temporary:effects.cache,support:[]),profile:profile,scope:scope)
        XCTAssertNotEqual(denied.code,0); XCTAssertFalse(fm.fileExists(atPath:root.appendingPathComponent(".git/forbidden").path))
        let patch="diff --git a/one b/one\n--- a/one\n+++ b/one\n@@ -1 +1 @@\n-two\n\\ No newline at end of file\n+three\n\\ No newline at end of file\n"
        let cached=try await effects.git(arguments:["apply","--cached","-"],scope:scope,patch:patch)
        XCTAssertEqual(cached.code,0,cached.text)
        let control=root.appendingPathComponent(".git/config"), before=try Data(contentsOf:control)
        let alias=try await effects.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","ln .git/config metadata-alias && printf forbidden >> metadata-alias"],directory:root,environment:SandboxEnvironment.execution(home:effects.cache,temporary:effects.cache,support:[]),profile:profile,scope:scope)
        XCTAssertNotEqual(alias.code,0,"Hard-link alias bypassed metadata write protection")
        XCTAssertEqual(try Data(contentsOf:control),before)
        grants.end(scope,reason:.finished)
    }
    @MainActor func testLinkedWorktreeMetadataReadOnlyAndChangedConfigFailClosed() async throws {
        let base=try temporary(), root=try repository(base), linked=base.appendingPathComponent("linked")
        try git(["worktree","add","-b","linked",linked.path],root)
        let inventory=try XCTUnwrap(SandboxGitRepository.discover(at:linked,home:base.appendingPathComponent("home")))
        XCTAssertNotEqual(inventory.gitDirectory.canonicalURL,inventory.commonDirectory.canonicalURL)
        let (effects,grants)=try effects(base,root:linked)
        effects.approvals.event={ event in if case .approval(let request)=event { try? effects.approvals.respond(request,response:.value("Allow Once")) } }
        let status=try await callGit(["status","--short"],effects); XCTAssertEqual(status.code,0,status.text)
        let scope=try grants.beginOperation(in:effects.activation), profile=try effects.profile(scope)
        for path in [inventory.gitDirectory.canonicalURL,inventory.commonDirectory.canonicalURL] {
            let result=try await effects.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf forbidden > \"$1/forbidden\"","sh",path.path],directory:linked,environment:SandboxEnvironment.execution(home:effects.cache,temporary:effects.cache,support:[]),profile:profile,scope:scope)
            XCTAssertNotEqual(result.code,0); XCTAssertFalse(fm.fileExists(atPath:path.appendingPathComponent("forbidden").path))
        }
        grants.end(scope,reason:.finished)
        try git(["config","user.name","Changed"],root)
        do { _=try await callGit(["add","--all"],effects); XCTFail("Changed config escaped identity check") } catch {}
        let (readonly,_)=try self.effects(base,root:root) { $0.projectConfiguration.access = .readOnly }
        do { _=try await callGit(["commit","--allow-empty","-m","denied"],readonly); XCTFail("Read Only bypass") } catch {}
    }
    @MainActor func testManagedJobOnceSessionRevocationRestartAndOwnerShutdown() async throws {
        let base=try temporary(), root=try repository(base), outside=base.appendingPathComponent("outside")
        try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        let (effects,grants)=try effects(base,root:root)
        var prompts=0, session=false
        effects.approvals.event={ event in if case .approval(let request)=event { prompts += 1; try? effects.approvals.respond(request,response:.value(session ? "Allow for Session" : "Allow Once")) } }
        let command="test -z \"${MILK_PI_LOCAL_KEY:-}${BASH_ENV:-}${NODE_OPTIONS:-}${GIT_CONFIG_COUNT:-}\" || exit 7; echo sanitized; while :; do echo live > '"+outside.appendingPathComponent("live").path+"'; sleep 0.1; done"
        let request=AgentManagedJobRequest(command:command,directory:root,purpose:.watcher,folders:[(outside,.readWrite)])
        let job=try await effects.startManaged(request)
        XCTAssertEqual(job.activation.sessionID,9); XCTAssertEqual(job.state,.running); XCTAssertEqual(prompts,1)
        try await Task.sleep(nanoseconds:200_000_000); XCTAssertTrue(job.output.contains("sanitized")); XCTAssertTrue(fm.fileExists(atPath:outside.appendingPathComponent("live").path))
        XCTAssertEqual(grants.grants.first?.operationID,job.scope?.id)
        let stableID=job.id; await job.stop(); XCTAssertEqual(job.state,.stopped); XCTAssertTrue(grants.grants.isEmpty)
        try await job.restart(); XCTAssertEqual(job.id,stableID); XCTAssertEqual(prompts,2); await job.stop()
        session=true; let other=try await effects.startManaged(request); XCTAssertEqual(prompts,3)
        let grant=try XCTUnwrap(grants.grants.first); grants.revokeSessionGrant(grant.id)
        await other.completion?.value; XCTAssertEqual(other.state,.stopped)
        let final=try await effects.startManaged(request); effects.shutdown(); await effects.shutdownAndWait(); XCTAssertEqual(final.state,.stopped)
        do { _=try await effects.startManaged(request); XCTFail("Retired activation launched a job") } catch {}
    }
}

@MainActor private final class WorkerProbeUI: MilkExtension {
    override func activate(context: any ExtensionContext) async throws {
        try context.contributions.command(.init(name:"worker-ui",summary:"Trusted native command") { _ in try context.storage.write(Data("trusted UI".utf8),to:"ui.txt") })
        try context.contributions.piTool(.init(id:"probe",description:"Disposable worker proof",parameters:Data(#"{"type":"object","properties":{"path":{"type":"string"},"action":{"type":"string"},"account":{"type":"string"}}}"#.utf8),requiredCapabilities:[.shell,.gitRead,.gitWrite],files:[.init(source:.argument,path:"path",writing:true)]))
    }
}
@MainActor private final class WorkerProbeLoader: NativeExtensionLoading {
    let keepsNativeCodeMapped=false
    func load(_ inspection: NativePackageInspection) throws -> MilkExtension { WorkerProbeUI() }
}
extension SandboxHostEffectsTests {
    func workerPackage(_ base: URL) throws -> URL {
        let package=base.appendingPathComponent("Probe.milkext"), binary=package.appendingPathComponent("Contents/MacOS/WorkerProbe")
        try fm.createDirectory(at:binary.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.createDirectory(at:package.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let manifest=ExtensionManifest(id:"dev.example.worker",name:"Worker Probe",version:"1.0.0",principalClass:"WorkerProbe.NativeUI",executable:"WorkerProbe",agentWorkerClass:"WorkerProbe.Worker",capabilities:[.pi,.shell,.gitRead,.gitWrite])
        try JSONEncoder().encode(manifest).write(to:package.appendingPathComponent("Contents/Resources/manifest.json"))
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":manifest.id,"CFBundlePackageType":"BNDL","CFBundleExecutable":manifest.executable,"NSPrincipalClass":manifest.principalClass],format:.xml,options:0).write(to:package.appendingPathComponent("Contents/Info.plist"))
        let source=base.appendingPathComponent("WorkerProbe.swift")
        try Data(#"""
        import Foundation
        import Security
        import MilkExtensionKit
        public final class Worker: MilkExtensionAgentWorker {
            public override func run(tool: String, arguments: Data, context: ExtensionAgentContext) async throws -> String {
                let args=try JSONSerialization.jsonObject(with:arguments) as! [String:String]
                let target=URL(fileURLWithPath:args["path"]!)
                if args["action"] == "keychain" {
                    var previous:DarwinBoolean=false
                    _=SecKeychainGetUserInteractionAllowed(&previous)
                    _=SecKeychainSetUserInteractionAllowed(false)
                    defer { _=SecKeychainSetUserInteractionAllowed(previous.boolValue) }
                    let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.milk.agent-provider.login.v1",kSecAttrAccount as String:args["account"]!,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
                    var value:CFTypeRef?
                    let status=SecItemCopyMatching(query as CFDictionary,&value)
                    return status == errSecSuccess ? "BYPASS:keychain-readable" : "keychain-denied=\(status)"
                }
                if args["action"] == "sleep" { try await Task.sleep(nanoseconds:10_000_000_000); try Data("late".utf8).write(to:target); return "late" }
                if args["action"] == "git" {
                    var direct="denied"
                    do { try Data("escape".utf8).write(to:context.workspaceURL.appendingPathComponent(".git/forbidden")); direct="BYPASS" } catch {}
                    return direct+"\n"+(try await context.git(arguments:["branch","worker-branch"]))
                }
                if args["action"] == "escape" {
                    do { try Data("escape".utf8).write(to:target.deletingLastPathComponent().appendingPathComponent("undeclared")); return "BYPASS" } catch { return "denied" }
                }
                let p=Process(), output=Pipe(); p.executableURL=URL(fileURLWithPath:"/bin/sh"); p.arguments=["-c","test -z \"${MILK_PI_LOCAL_KEY:-}${BASH_ENV:-}${NODE_OPTIONS:-}${GIT_CONFIG_COUNT:-}\" && echo clean"]
                p.standardOutput=output; try p.run(); let child=output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                try Data("worker".utf8).write(to:target)
                return "pid=\(getpid()) key=\(ProcessInfo.processInfo.environment["MILK_PI_LOCAL_KEY"] == nil) child=\(String(decoding:child,as:UTF8.self))"
            }
        }
        """#.utf8).write(to:source)
        let sdk=project.appendingPathComponent(".build/arm64-apple-macosx/debug"), process=Process(), output=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun")
        process.arguments=["swiftc","-swift-version","5","-target","arm64-apple-macosx26.0","-parse-as-library","-emit-library","-Xlinker","-bundle","-module-name","WorkerProbe","-I",sdk.appendingPathComponent("Modules").path,"-L",sdk.path,"-lMilkExtensionKit",source.path,"-o",binary.path]
        process.environment=["PATH":"/usr/bin:/bin","DEVELOPER_DIR":"/Applications/Xcode.app/Contents/Developer","CLANG_MODULE_CACHE_PATH":project.appendingPathComponent(".build/clang-cache").path]
        process.standardOutput=output; process.standardError=output; try process.run(); let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentError.message(String(decoding:data,as:UTF8.self)) }
        return package
    }
    @MainActor func testActualExtensionWorkerIsolationProtectedOnceSessionGitCancellationAndNativeUI() async throws {
        let base=try temporary(), root=try repository(base), package=try workerPackage(base)
        let manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:WorkerProbeLoader())
        await manager.setWorkspace(root); let review=try manager.inspect(package)
        try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities)
        let executed=try await manager.executeCommand("worker-ui",arguments:""); XCTAssertTrue(executed)
        XCTAssertEqual(try String(contentsOf:manager.dataURL("dev.example.worker").appendingPathComponent("ui.txt"),encoding:.utf8),"trusted UI")
        let protected=base.appendingPathComponent("protected"), outside=base.appendingPathComponent("outside")
        try fm.createDirectory(at:protected,withIntermediateDirectories:true); try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        let (effects,grants)=try effects(base,root:root) { $0.configuration.protectedLocations=[.init(url:protected)] }
        let tool=try XCTUnwrap(manager.registry.tools.first)
        let helper=ProcessInfo.processInfo.environment["MILK_TEST_WORKER_PATH"].map { URL(fileURLWithPath:$0) } ?? project.appendingPathComponent(".build/arm64-apple-macosx/debug/MilkExtensionWorker")
        var requests: [AgentApproval]=[], session=false
        effects.approvals.event={ event in if case .approval(let request)=event { requests.append(request); try? effects.approvals.respond(request,response:.value(session && request.risk != "Protected" ? "Allow for Session" : "Allow Once")) } }
        func invoke(_ path: URL, action: String = "probe") async throws -> String {
            let scope=try grants.beginOperation(in:effects.activation); defer { grants.end(scope,reason:.finished) }
            return try await effects.extensionTool(id:tool.id,arguments:.object(["path":.string(path.path),"action":.string(action)]),manager:manager,scope:scope,helper:helper).text
        }
        let target=protected.appendingPathComponent("file")
        let first=try await invoke(target)
        XCTAssertTrue(first.contains("key=true"),first); XCTAssertTrue(first.contains("child=clean"),first); XCTAssertFalse(first.contains("pid=\(getpid()) "),first)
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"worker"); XCTAssertEqual(requests.last?.risk,"Protected"); XCTAssertFalse(requests.last?.options.contains("Allow for Session") ?? true)
        XCTAssertTrue(grants.grants.isEmpty)
        _=try await invoke(target); XCTAssertEqual(requests.count,2)
        let denied=try await invoke(target,action:"escape"); XCTAssertEqual(denied,"denied"); XCTAssertFalse(fm.fileExists(atPath:protected.appendingPathComponent("undeclared").path))
        session=true; let shared=outside.appendingPathComponent("shared"); _=try await invoke(shared)
        let count=requests.filter { $0.origin == .milkSandbox }.count
        _=try await invoke(shared); XCTAssertEqual(requests.filter { $0.origin == .milkSandbox }.count,count,"Session file grant should be reused; ordinary Ask remains separate when needed")
        let result=try await invoke(root.appendingPathComponent("normal"),action:"git"); XCTAssertTrue(result.hasPrefix("denied"),result)
        XCTAssertFalse(fm.fileExists(atPath:root.appendingPathComponent(".git/forbidden").path)); XCTAssertTrue(try git(["branch","--list"],root).contains("worker-branch"))
        let retained=Task { try await invoke(shared,action:"sleep") }
        let ready=Date().addingTimeInterval(3)
        while effects.processes.values.flatMap({ $0 }).isEmpty && Date() < ready { try await Task.sleep(nanoseconds:10_000_000) }
        let sharedPath=try SandboxPathResolver().resolve(shared).canonicalURL.path
        let sessionGrant=try XCTUnwrap(grants.grants.first { $0.path.canonicalURL.path == sharedPath && $0.subject == .extensionWorker })
        grants.revokeSessionGrant(sessionGrant.id)
        do { _=try await retained.value; XCTFail("Worker survived admission after Session revocation") } catch {}
        let pending=Task { try await invoke(outside.appendingPathComponent("late"),action:"sleep") }
        try await Task.sleep(nanoseconds:300_000_000); pending.cancel()
        do { _=try await pending.value; XCTFail("Cancelled worker returned success") } catch {}
        XCTAssertFalse(fm.fileExists(atPath:outside.appendingPathComponent("late").path))
        let revoke=Task { try await invoke(outside.appendingPathComponent("revoke"),action:"sleep") }
        try await Task.sleep(nanoseconds:300_000_000); try await manager.setEnabled(tool.owner,false)
        do { _=try await revoke.value; XCTFail("Revoked worker returned success") } catch {}
        await manager.shutdown()
    }
    @MainActor func testActualWorkerCannotReadMilkNormalKeychainItem() async throws {
        guard let app=ProcessInfo.processInfo.environment["MILK_TEST_KEYCHAIN_APP"],
              let helper=ProcessInfo.processInfo.environment["MILK_TEST_WORKER_PATH"] else {
            throw XCTSkip("Opt-in actual normal-Keychain acceptance requires the built app and packaged worker selectors.")
        }
        let run=UUID().uuidString, base=try temporary(), root=try repository(base)
        func verify(_ phase: String) throws {
            let process=Process(), output=Pipe()
            process.executableURL=URL(fileURLWithPath:app).appendingPathComponent("Contents/MacOS/Milk")
            process.arguments=["--verify-provider-keychain","--keychain-run-id",run,"--keychain-phase",phase]
            process.standardOutput=output; process.standardError=output
            try process.run(); let data=output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AgentError.message(String(decoding:data,as:UTF8.self)) }
        }
        try verify("keep")
        defer { do { try verify("cleanup") } catch { XCTFail("Disposable actual-Keychain cleanup failed: \(error)") } }
        let account=AgentProviderCredentials.account(agent:.pi,provider:"verification",endpoint:URL(string:"https://keychain-verification.invalid/"+run)!,profile:"verification-"+run)
        let package=try workerPackage(base), manager=NativeExtensionManager(root:base.appendingPathComponent("support"),loader:WorkerProbeLoader())
        await manager.setWorkspace(root); let review=try manager.inspect(package)
        try await manager.install(review,trusting:review.fingerprint,granting:review.capabilities)
        let tool=try XCTUnwrap(manager.registry.tools.first)
        for enabled in [true,false] {
            let (effects,grants)=try self.effects(base,root:root) { $0.configuration.enabled=enabled }
            let scope=try grants.beginOperation(in:effects.activation)
            let result=try await effects.extensionTool(id:tool.id,arguments:.object(["path":.string(root.appendingPathComponent("unused").path),"action":.string("keychain"),"account":.string(account)]),manager:manager,scope:scope,helper:URL(fileURLWithPath:helper))
            XCTAssertTrue(result.text.hasPrefix("keychain-denied="),"Separate worker read Milk's item: \(result.text)")
            grants.end(scope,reason:.finished); await effects.shutdownAndWait()
            try verify("read") // The creating Milk app still reads the same physical item.
        }
        await manager.shutdown()
    }
}

extension SandboxHostEffectsTests {
    @MainActor func testAgentPreviewOriginCannotFallBackAndManagedServerUsesSanitizedExecutor() async throws {
        _=NSApplication.shared
        let base=try temporary(), root=try repository(base)
        let (effects,_)=try effects(base,root:root)
        let config=PreviewConfiguration(command:"echo untrusted",directory:root,agentSuggested:true,agentReceipt:UUID())
        let trusted=DevServerService()
        XCTAssertThrowsError(try trusted.launch(config,workspace:root))
        let decoded=try JSONDecoder().decode(PreviewConfiguration.self,from:JSONEncoder().encode(config))
        XCTAssertEqual(decoded.agentSuggested,true); XCTAssertNil(decoded.agentReceipt)
        let script=root.appendingPathComponent("server.py")
        try Data("""
        import http.server,os
        assert not os.environ.get('MILK_PI_LOCAL_KEY')
        assert not os.environ.get('BASH_ENV')
        server=http.server.HTTPServer(('127.0.0.1',0),http.server.SimpleHTTPRequestHandler)
        print('http://127.0.0.1:'+str(server.server_port),flush=True)
        server.serve_forever()
        """.utf8).write(to:script)
        let suite="Milk.AgentPreview."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let preview=PreviewService(defaults:defaults,devServers:trusted)
        preview.authorize={ $0 }
        preview.assist={ _ in .init(command:"/usr/bin/python3 -u server.py",directory:root) }
        var managed: AgentManagedJob?
        preview.launchAgent={ request in
            XCTAssertEqual(request.agentSuggested,true)
            let job=try await effects.startManaged(.init(command:request.command,directory:request.directory,purpose:.preview)); managed=job; return job
        }
        preview.setWorkspace(root); preview.start()
        let deadline=Date().addingTimeInterval(15)
        while preview.currentURL == nil && preview.state != .failed { guard Date() < deadline else { XCTFail("Agent Preview startup timeout"); break }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertNotNil(preview.currentURL,preview.error ?? "")
        let job=try XCTUnwrap(managed); XCTAssertEqual(job.state,.running); XCTAssertTrue(preview.server?.agentJob === job)
        let memory=try XCTUnwrap(defaults.data(forKey:"Milk.preview.v1")), text=String(decoding:memory,as:UTF8.self)
        XCTAssertFalse(text.contains("server.py"),"Agent commands must never persist as trusted launch configurations")
        preview.stop(); await job.completion?.value
        XCTAssertEqual(job.state,.stopped); let stopped=await preview.shutdown(); XCTAssertTrue(stopped)
        let refused=PreviewService(persist:false)
        refused.authorize={ $0 }; refused.assist={ _ in config }; refused.setWorkspace(root); refused.start()
        let end=Date().addingTimeInterval(3)
        while refused.state != .failed && Date() < end { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertEqual(refused.state,.failed); XCTAssertNil(refused.server); _=await refused.shutdown()
    }
    @MainActor func testLocalRemoteFetchPullPushMergeResetRestoreAndProtectedGitFlow() async throws {
        let base=try temporary(), root=try repository(base), remote=base.appendingPathComponent("remote.git")
        try git(["init","--bare",remote.path],root); try git(["remote","add","origin",remote.path],root)
        let (effects,_)=try effects(base,root:root)
        for argv in [["push","-u","origin","main"],["fetch","origin"],["pull","--ff-only","origin","main"],["switch","-c","feature"]] {
            let result=try await callGit(argv,effects); XCTAssertEqual(result.code,0,result.text)
        }
        try Data("new".utf8).write(to:root.appendingPathComponent("new"))
        for argv in [["add","new"],["restore","--staged","new"],["add","new"],["commit","-m","feature"],["switch","main"],["merge","--ff-only","feature"],["reset","--soft","HEAD~1"]] {
            let result=try await callGit(argv,effects); XCTAssertEqual(result.code,0,result.text)
        }
        let protected=root.appendingPathComponent("private"), (gated,_)=try self.effects(base,root:root) { $0.configuration.protectedLocations=[.init(url:root.appendingPathComponent("private"))] }
        try fm.createDirectory(at:protected,withIntermediateDirectories:true)
        var asks: [AgentApproval]=[]
        gated.approvals.event={ event in if case .approval(let request)=event { asks.append(request); try? gated.approvals.respond(request,response:.value("Deny")) } }
        do { _=try await callGit(["reset","--hard","HEAD"],gated); XCTFail("Protected subtree bypassed") } catch {}
        XCTAssertEqual(asks.last?.risk,"Protected"); XCTAssertTrue(asks.last?.effect?.contains("hooks/helpers") == true)
    }
}
