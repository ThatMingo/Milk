import XCTest
@testable import Milk

final class SandboxPiIntegrationTests: XCTestCase {
    @MainActor private func wait(_ message: String, until: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !until() { guard Date() < end else { throw AgentError.message("Timed out: " + message) }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    @MainActor func testProductionBackendBridgeNestedToolsCredentialDomainAndUnknownRejection() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Sandbox-Pi-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("project"), profile = root.appendingPathComponent("profile"), outside = root.appendingPathComponent("outside")
        for url in [workspace, profile, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("nested-input".utf8).write(to: workspace.appendingPathComponent("input.txt"))
        try Data("once-outside".utf8).write(to: outside.appendingPathComponent("data"))
        let script = workspace.appendingPathComponent("runtime-probe.ts")
        let js = #"""
        import {spawnSync} from 'node:child_process';
        import {writeFileSync} from 'node:fs';
        import {Type} from '@earendil-works/pi-ai';
        export default function(pi:any){
          pi.registerMcpServer('phase4',{command:'/usr/bin/python3',args:[process.cwd()+'/mcp-probe.py',process.cwd()+'/mcp-proof.json'],exposure:'direct'});
          pi.registerTool({name:'unmapped_tool',description:'Must fail before the handler',parameters:Type.Object({}),execute:async()=>{writeFileSync('unknown-ran','bad');return{content:[{type:'text',text:'bad'}]};}});
          pi.registerCommand('sandbox-probe',{description:'Synthetic runtime domain proof',handler:async(_a:any,ctx:any)=>{

            const exec=await pi.exec('/bin/sh',['-c','test -n "$MILK_PI_LOCAL_KEY"']);
            const spawn=spawnSync('/bin/sh',['-c','test -n "$MILK_PI_LOCAL_KEY"']);
            const denied=await pi.exec('/bin/sh',['-c','cat "$1"','sh',process.cwd()+'/../outside/data']);
            writeFileSync('runtime-proof.json',JSON.stringify({execHasKey:exec.code===0,spawnHasKey:spawn.status===0,fixedOutsideDenied:denied.code!==0}));
          }});
        }
        """#
        try Data(js.utf8).write(to: script)
        try FileManager.default.copyItem(at:project.appendingPathComponent("Tests/SandboxPhase1/mcp_probe.py"),to:workspace.appendingPathComponent("mcp-probe.py"))
        try JSONSerialization.data(withJSONObject: ["extensions":[script.path]]).write(to: profile.appendingPathComponent("settings.json"))
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-u",project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice; try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let suite = "Milk.SandboxPi." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = SandboxConfiguration(home: root); config.protectedLocations = [.init(url: outside)]
        defaults.set(try JSONEncoder().encode(config), forKey: SandboxSettingsStore.key)
        let settings = SandboxSettingsStore(defaults: defaults, home: root)
        let credentialStore = CredentialTestStore(); defer { credentialStore.restore() }
        var provider = PiProviderConfiguration(); provider.provider = .local
        provider.local.endpoint = URL(string:"http://127.0.0.1:\(port)")!; provider.local.authentication = .apiKey
        provider.local.models = [.init(id:"milk-fixture", contextWindow:32000, maxTokens:2048, reasoning:false, images:true)]; provider.local.selectedModel = "milk-fixture"
        try AgentProviderCredentials.save("phase3-synthetic-not-live", agent:.pi, provider:"local",endpoint:provider.local.endpoint)
        // Exercise nested ToolExecutionContext from the same extension owner, without
        // modifying upstream Pi or adding a production-only test route.
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["MilkPiIntegration.ts", "MilkSandboxBridge.ts", "MilkSandboxWorker.ts"] {
            var source = try String(contentsOf: project.appendingPathComponent("Runtime/" + name), encoding: .utf8)
            if name == "MilkPiIntegration.ts" {
                source = source.replacingOccurrences(of: "  installSandboxBridge(pi);", with: """
                  installSandboxBridge(pi);
                  pi.registerTool({name:'ls',description:'Synthetic nested read',parameters:Type.Object({}),execute:async(_id:any,_args:any,signal:any,onUpdate:any,ctx:any)=>ctx.executeTool('read',{path:'input.txt'},{signal,onUpdate})});
                """)
            }
            try Data(source.utf8).write(to: resources.appendingPathComponent(name))
        }
        func setupGit(_ arguments: [String]) throws {
            let process=Process(); process.executableURL=URL(fileURLWithPath:"/usr/bin/git"); process.arguments=arguments; process.currentDirectoryURL=workspace
            process.environment=["PATH":"/usr/bin:/bin","HOME":root.path,"GIT_CONFIG_NOSYSTEM":"1"]; process.standardOutput=FileHandle.nullDevice; process.standardError=FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        }
        try setupGit(["init","-b","main"]); try setupGit(["config","user.name","Milk Test"]); try setupGit(["config","user.email","synthetic@example.invalid"])
        let runtime = PiRuntimeService(resources: resources, environmentOverrides:["PI_CODING_AGENT_DIR":profile.path,"MILK_PI_LOCAL_KEY":"stale-ambient-not-authority","OPENAI_API_KEY":"synthetic-phase4-other-provider","BASH_ENV":"/must/not/source","NODE_OPTIONS":"--require=/must/not/load"])
        var agentConfig = AgentConfiguration(); agentConfig.defaultPermission = .autonomous
        agentConfig.runtime = .external(project.appendingPathComponent("Runtime/PiRuntime/pi"))
        let backend = PiBackend(sandboxSettings: settings, runtime: runtime, configuration: agentConfig, providerConfiguration: provider)
        defer { backend.onEvent = nil; backend.shutdown() }
        var settled = 0, prompts = 0, failures: [String] = [], activities: [AgentActivity] = []
        backend.onEvent = { event in
            switch event {
            case .settled: settled += 1
            case .approval(let request): prompts += 1; XCTAssertEqual(request.origin,.milkSandbox); try? backend.respond(request,response:.value("Allow Once"))
            case .activity(let value): activities.append(value)
            case .failure(let value): failures.append(value)
            default: break
            }
        }
        try await backend.start(workspace: workspace, session:.init(id:1,title:"Sandbox proof"))
        func tool(_ name: String, _ arguments: JSONValue) async throws {
            let before = settled
            let instruction = "sandbox-tool-fixture " + JSONValue.array([.string(name),arguments]).encodedString
            try await backend.send(.init(text:instruction,attachments:[]),intent:.prompt)
            try await wait("tool completion") { settled > before || !failures.isEmpty }
            XCTAssertTrue(failures.isEmpty, failures.joined(separator:"\n"))
        }
        try await tool("write",.object(["path":.string("written.txt"),"content":.string("real-main-bridge")]))
        XCTAssertEqual(try String(contentsOf:workspace.appendingPathComponent("written.txt"),encoding:.utf8),"real-main-bridge")
        try await tool("read",.object(["path":.string(outside.appendingPathComponent("data").path)]))
        XCTAssertEqual(prompts,1)
        try await tool("ls",.object([:]))
        XCTAssertTrue(activities.contains { $0.output.contains("nested-input") }, "Nested read did not traverse the production bridge: " + activities.map { $0.output }.joined(separator:" | "))
        try await tool("milk_git",.object(["arguments":.array([.string("add"),.string("--"),.string("written.txt")])]))
        try await tool("milk_git",.object(["arguments":.array([.string("commit"),.string("-m"),.string("bridge proof")])]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:workspace.appendingPathComponent(".git/HEAD").path))
        try await tool("bash",.object(["command":.string("printf forbidden > .git/forbidden")]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.appendingPathComponent(".git/forbidden").path))
        try await tool("milk_job",.object(["action":.string("start"),"purpose":.string("background"),"command":.string("echo managed-ready > managed-ready; test -z \"$MILK_PI_LOCAL_KEY\" || exit 7; while :; do sleep 0.1; done")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:workspace.appendingPathComponent("managed-ready").path))
        try await tool("unmapped_tool",.object([:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.appendingPathComponent("unknown-ran").path))
        let slow: JSONValue = .array([.string("bash"),.object(["command":.string("printf ready > cancel-ready; sleep 2; printf leak > cancel-late")])])
        try await backend.send(.init(text:"sandbox-tool-fixture " + slow.encodedString,attachments:[]),intent:.prompt)
        try await wait("production model tool start") { FileManager.default.fileExists(atPath:workspace.appendingPathComponent("cancel-ready").path) }
        try await backend.stop()
        try await Task.sleep(nanoseconds:2_100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath:workspace.appendingPathComponent("cancel-late").path))
        try await backend.send(.init(text:"/sandbox-probe",attachments:[]),intent:.prompt)
        try await wait("runtime probe") { FileManager.default.fileExists(atPath: workspace.appendingPathComponent("runtime-proof.json").path) }
        let proof = try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:workspace.appendingPathComponent("runtime-proof.json")))
        XCTAssertTrue(proof["execHasKey"].bool); XCTAssertTrue(proof["spawnHasKey"].bool)
        XCTAssertTrue(proof["fixedOutsideDenied"].bool)
        try await wait("Pi-owned stdio MCP inheritance") { FileManager.default.fileExists(atPath:workspace.appendingPathComponent("mcp-proof.json").path) }
        let mcp = try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:workspace.appendingPathComponent("mcp-proof.json")))
        XCTAssertTrue(mcp["inherited"].bool)
        XCTAssertTrue(activities.contains { $0.output.contains("real-main-bridge") || $0.output.contains("once-outside") })
        try await backend.shutdownAndWait()
    }
}
