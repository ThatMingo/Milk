import XCTest
@testable import Milk

/// Real pinned Pi, with temporary extension/template/skill resources and a local provider fixture.
final class SlashCommandPiTests: XCTestCase {
    @MainActor func testRealPiDiscoversResourcesPreservesMetadataAndExecutesCommandsThroughRPC() async throws {
        let fm=FileManager.default
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root=fm.temporaryDirectory.appendingPathComponent("Milk-Slash-Pi-"+UUID().uuidString), workspace=root.appendingPathComponent("workspace"), agent=root.appendingPathComponent("agent")
        for path in [workspace,agent.appendingPathComponent("extensions"),agent.appendingPathComponent("prompts"),agent.appendingPathComponent("skills/slash-review")] { try fm.createDirectory(at:path,withIntermediateDirectories:true) }
        defer { try? fm.removeItem(at:root) }
        let source="""
        export default function(pi: any) {
          pi.registerCommand("catalog-fixture", {
            description: "Run catalog fixture",
            handler: async (args: string, ctx: any) => {
              ctx.ui.notify("ARGS:" + args, "info");
              pi.registerCommand("late-fixture", { description: "Late registered command", handler: async (_args: string, ctx: any) => { ctx.ui.notify("LATE", "info"); } });
            }
          });
        }
        """
        try Data(source.utf8).write(to:agent.appendingPathComponent("extensions/catalog.ts"))
        try Data("---\ndescription: Review template fixture\n---\nTemplate fixture request: $ARGUMENTS\n".utf8).write(to:agent.appendingPathComponent("prompts/slash-template.md"))
        try Data("---\nname: slash-review\ndescription: Review skill fixture\n---\nRead the requested project carefully.\n".utf8).write(to:agent.appendingPathComponent("skills/slash-review/SKILL.md"))
        try Data(#"{"enableSkillCommands":true}"#.utf8).write(to:agent.appendingPathComponent("settings.json"))
        let server=Process(), output=Pipe(); server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        server.arguments=["-u",project.appendingPathComponent("Tests/Fixtures/local_provider_fixture.py").path]; server.standardOutput=output; server.standardError=FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        let port=try XCTUnwrap(Int(String(decoding:output.fileHandleForReading.availableData,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        let runtime=PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["PI_CODING_AGENT_DIR":agent.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"])
        var configuration = AgentConfiguration(); var provider = PiProviderConfiguration(); provider.provider = .local; provider.local.endpoint=URL(string:"http://127.0.0.1:\(port)")!
        provider.local.models = ["milk-fixture"].map { .init(id: $0, contextWindow: 64000, maxTokens: 4096, reasoning: $0 == "reasoning-fixture", images: false) }; provider.local.selectedModel="milk-fixture"
        let backend=PiBackend(runtime:runtime, providerConfiguration:provider); defer { backend.shutdown() }
        var catalog:[AgentCommand]=[], notices:[String]=[], failures:[String]=[], messages:[AgentMessage]=[], settled=0
        backend.onEvent={ event in
            switch event {
            case .slashCommands(let values): catalog=values
            case .notice(let text): notices.append(text)
            case .failure(let text), .extensionProblem(let text): failures.append(text)
            case .message(let message): messages.append(message)
            case .settled: settled += 1
            default: break
            }
        }
        try await backend.start(workspace:workspace,session:.init(id:0,title:"Slash catalog"),configuration:configuration)
        let extensionCommand=try XCTUnwrap(catalog.first { $0.name == "catalog-fixture" })
        XCTAssertEqual(extensionCommand.source,.extension); XCTAssertEqual(extensionCommand.description,"Run catalog fixture")
        XCTAssertEqual(extensionCommand.sourceInfo?.path,agent.appendingPathComponent("extensions/catalog.ts").path)
        XCTAssertEqual(catalog.first { $0.name == "slash-template" }?.source,.prompt)
        XCTAssertEqual(catalog.first { $0.name == "slash-template" }?.description,"Review template fixture")
        XCTAssertEqual(catalog.first { $0.name == "skill:slash-review" }?.source,.skill)
        XCTAssertFalse(catalog.contains { ["model","settings","new","quit","hotkeys","milk-permission"].contains($0.name) })
        try await backend.send(.init(text:"/catalog-fixture alpha  beta",attachments:[]))
        XCTAssertTrue(notices.contains("ARGS:alpha  beta")); XCTAssertTrue(messages.isEmpty,"A handled resource command is not a model prompt")
        XCTAssertTrue(catalog.contains { $0.name == "late-fixture" },"Handled commands refresh Pi's dynamic catalog")
        func wait(_ count: Int) async throws {
            let end=Date().addingTimeInterval(15)
            while settled < count { guard Date() < end else { throw AgentError.message("Timed out: "+failures.joined(separator:"; ")) }; try await Task.sleep(nanoseconds:20_000_000) }
        }
        try await backend.send(.init(text:"/slash-template supplied-argument",attachments:[])); try await wait(2)
        XCTAssertTrue(messages.contains { $0.role == "user" && $0.text.contains("Template fixture request: supplied-argument") })
        try await backend.send(.init(text:"/skill:slash-review inspect this",attachments:[])); try await wait(3)
        XCTAssertTrue(messages.contains { $0.role == "user" && $0.text.contains("slash-review") })
        XCTAssertTrue(failures.isEmpty,failures.joined(separator:"\n")); try await backend.shutdownAndWait()
    }
}
