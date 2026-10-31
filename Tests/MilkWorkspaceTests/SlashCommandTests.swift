import XCTest
import AppKit
import SwiftUI
import MilkLayout
@testable import Milk

@MainActor private final class SlashBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var sent: [(AgentPrompt,AgentSubmissionIntent)] = []
    var names: [String] = []
    var stopped=false
    var steered: [AgentPrompt] = []
    var discovered: [AgentCommand] = []
    var refreshCount=0
    var refreshDelay: UInt64=0
    var refreshFails=false
    func start(workspace: URL, session: AgentSession) async throws {
        onEvent?(.state(.init(sessionFile:workspace.appendingPathComponent(session.backendID+".jsonl").path,sessionID:session.backendID,name:session.title,model:.init(provider:"test",modelID:"test",name:"Test",supportsImages:false),effort:"off",running:false)))
        onEvent?(.models([.init(provider:"test",modelID:"test",name:"Test",supportsImages:false)]))
        onEvent?(.efforts(["off","high"],selected:"off"))
        onEvent?(.slashCommands(discovered))
    }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent) async throws {
        sent.append((prompt,intent))
        if !prompt.text.hasPrefix("/") { onEvent?(.started) }
    }
    func stop() async throws { stopped=true; onEvent?(.settled(aborted:true)) }
    func clearQueue() async throws { onEvent?(.queue(followUp:[],steering:[])) }
    func steerQueued(_ prompt: AgentPrompt) async throws { steered.append(prompt) }
    func setModel(_ model: AgentModel) async throws {}
    func setEffort(_ effort: String) async throws {}
    func setPermission(_ mode: ComposerPermissionMode) async throws {}
    func rename(_ title: String) async throws { names.append(title); onEvent?(.sessionName(title)) }
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws { onEvent?(.dismissApproval(approval.id)) }
    func refreshCommands() async throws {
        refreshCount += 1
        let failure=refreshFails, delay=refreshDelay
        if delay > 0 { try await Task.sleep(nanoseconds:delay) }
        if failure { throw AgentError.message("Old discovery failed") }
        onEvent?(.slashCommands(discovered))
    }
    func shutdown() { stopped=true }
    func shutdownAndWait() async throws { shutdown() }
}

final class SlashCommandTests: XCTestCase {
    @MainActor private func fixture() throws -> (ShellState,SlashBackend,URL) {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Slash-Test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="Milk.SlashTests."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!, backend=SlashBackend()
        let state=ShellState(persist:false,preferences:defaults,backendFactory:{backend})
        try state.workspace.openWorkspace(root)
        addTeardownBlock { await state.agent.shutdown(); await state.nativeExtensions.shutdown(); _ = await state.terminal.shutdown(); UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        return (state,backend,root)
    }
    @MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let until=Date().addingTimeInterval(5)
        while !condition() { guard Date() < until else { throw AgentError.message("Timeout: "+label) }; try await Task.sleep(nanoseconds:5_000_000) }
    }
    @MainActor private func service(_ draft: String = "/") -> SlashCommandService {
        let value=SlashCommandService(); value.synchronize(commands:SlashCommandCatalog.core,input:draft,session:0,approval:false); return value
    }
    @MainActor func testTriggerFilteringKeyboardCompletionEscapeAndDeletion() {
        let menu=service()
        XCTAssertEqual(menu.popup,.slash); XCTAssertEqual(menu.results.count,9); XCTAssertEqual(menu.selectedID,"new")
        XCTAssertTrue(menu.handle(.down)); XCTAssertEqual(menu.selectedID,"resume")
        XCTAssertTrue(menu.handle(.up)); XCTAssertEqual(menu.selectedID,"new")
        XCTAssertTrue(menu.handle(.up)); XCTAssertEqual(menu.selectedID,"quit")
        menu.synchronize(commands:SlashCommandCatalog.core,input:"  /mo",session:0,approval:false)
        XCTAssertEqual(menu.results.first?.name,"model")
        var inserted=""; menu.applyInput={inserted=$0}
        XCTAssertTrue(menu.handle(.tab)); XCTAssertEqual(inserted,"/model "); XCTAssertNil(menu.popup)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/ne",session:0,approval:false)
        XCTAssertEqual(menu.results.first?.name,"new")
        XCTAssertTrue(menu.handle(.escape)); XCTAssertNil(menu.popup)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/ne",session:0,approval:false); XCTAssertNil(menu.popup,"A refresh must not undo Escape")
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/new",session:0,approval:false); XCTAssertEqual(menu.popup,.slash)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"new",session:0,approval:false); XCTAssertNil(menu.popup)
        XCTAssertFalse(menu.handle(.down)); XCTAssertFalse(menu.handle(.enter))
        menu.synchronize(commands:SlashCommandCatalog.core,input:"Fix src/views/foo/bar.swift",session:0,approval:false)
        XCTAssertNil(menu.popup); XCTAssertFalse(menu.submit())
    }
    @MainActor func testArgumentCompletionUnknownSyntaxEmptyResultsAndAvailability() {
        let menu=service("/na")
        var inserted="", executed:[String]=[]; menu.applyInput={ inserted=$0 }; menu.execute={ command,_ in executed.append(command.name) }
        XCTAssertTrue(menu.handle(.enter)); XCTAssertEqual(inserted,"/name "); XCTAssertTrue(executed.isEmpty)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/name",session:0,approval:false)
        XCTAssertTrue(menu.submit()); XCTAssertEqual(inserted,"/name "); XCTAssertTrue(executed.isEmpty)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/name Test",session:0,approval:false); XCTAssertTrue(menu.submit()); XCTAssertEqual(executed,["name"])
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/new please fix this",session:0,approval:false); XCTAssertTrue(menu.submit()); XCTAssertEqual(menu.error,"Usage: /new"); XCTAssertEqual(executed,["name"])
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/not-a-command",session:0,approval:false)
        XCTAssertTrue(menu.results.isEmpty); XCTAssertEqual(menu.popup,.slash); XCTAssertTrue(menu.submit()); XCTAssertEqual(menu.error,"Unknown command: /not-a-command")
        var disabled=SlashCommandCatalog.core; disabled[0].unavailable="Open a workspace first."
        menu.synchronize(commands:disabled,input:"/new",session:0,approval:false); menu.handle(.enter)
        XCTAssertEqual(menu.error,"Open a workspace first."); XCTAssertEqual(executed,["name"])
    }
    @MainActor func testDiscoveryMetadataOrderingPrefixesAndNoBlindTUICommands() throws {
        let values:[JSONValue] = [
            .object(["name":.string("skill:review"),"description":.string("Review skill"),"source":.string("skill"),"sourceInfo":.object(["path":.string("/skills/review/SKILL.md"),"scope":.string("project")])]),
            .object(["name":.string("my-template"),"source":.string("prompt")]),
            .object(["name":.string("custom-extension-command"),"description":.string("Custom action"),"source":.string("extension")]),
            .object(["name":.string("hotkeys"),"source":.string("builtin")]),
            .object(["name":.string("unclassified"),"description":.string("Not safe to guess")])
        ]
        let pi=values.compactMap(PiCommandDecoder.decode)
        XCTAssertEqual(pi.count,3); XCTAssertNil(pi.first { $0.name == "my-template" }?.description)
        let catalog=SlashCommandCatalog.merge(core:SlashCommandCatalog.core,native:[],agent:pi)
        XCTAssertEqual(Array(catalog.suffix(3)).map(\.name),["custom-extension-command","my-template","skill:review"])
        XCTAssertEqual(catalog.last?.path,"/skills/review/SKILL.md"); XCTAssertEqual(pi.first?.sourceInfo?.scope,"project")
        XCTAssertFalse(catalog.contains { $0.name == "hotkeys" || $0.name == "clear" })
        XCTAssertEqual(SlashCommandCatalog.filtered(catalog,query:"se").first?.name,"settings")
        let duplicate=AgentCommand(name:"settings",description:"A dynamic collision",source:.extension)
        XCTAssertEqual(SlashCommandCatalog.merge(core:SlashCommandCatalog.core,native:[],agent:[duplicate]).filter { $0.name == "settings" }.count,1)
    }
    @MainActor func testPopupExclusionApprovalPriorityAndSessionSwitch() {
        let menu=service()
        menu.present(.model); XCTAssertEqual(menu.popup,.model)
        menu.present(.thinking); XCTAssertEqual(menu.popup,.thinking)
        menu.present(.permissions); XCTAssertEqual(menu.popup,.permissions)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/n",session:0,approval:false); XCTAssertEqual(menu.popup,.slash)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/n",session:0,approval:true); XCTAssertNil(menu.popup)
        menu.present(.model); XCTAssertNil(menu.popup); XCTAssertFalse(menu.handle(.enter))
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/n",session:0,approval:false); XCTAssertNil(menu.popup)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/ne",session:0,approval:false); XCTAssertEqual(menu.popup,.slash)
        menu.synchronize(commands:SlashCommandCatalog.core,input:"saved draft",session:1,approval:false); XCTAssertNil(menu.popup)
    }
    @MainActor func testNativeActionsReuseSessionsPickersSettingsTerminalAndQuit() async throws {
        let (state,backend,root)=try fixture()
        state.updateComposerDraft("connect"); state.submitComposerPrompt()
        try await wait("backend connected") { !state.agent.pendingActions.contains(state.selectedSession) && backend.sent.count == 1 }
        backend.onEvent?(.settled(aborted:false)); state.refreshSlashCommands()
        let original=state.selectedSession
        let attachment=PromptAttachment(url:root.appendingPathComponent("attached.txt"),projectFile:true)
        state.agent.current.attachments=[attachment]
        state.updateComposerDraft("/name Test"); state.submitComposerPrompt()
        try await wait("real session renamed") { state.agent.currentSession?.title == "Test" }
        XCTAssertEqual(backend.names,["Test"]); XCTAssertEqual(backend.sent.count,1)
        for (text,popup) in [("/model",ComposerPopup.model),("/thinking",.thinking)] {
            state.updateComposerDraft(text); state.submitComposerPrompt(); XCTAssertEqual(state.slashCommands.popup,popup)
        }
        state.updateComposerDraft("/settings"); state.submitComposerPrompt(); XCTAssertEqual(state.takeover,"Settings")
        state.updateComposerDraft("/extensions"); state.submitComposerPrompt(); XCTAssertEqual(state.takeover,"Extensions")
        state.updateComposerDraft("/resume"); state.submitComposerPrompt(); XCTAssertEqual(state.destination,"Sessions"); XCTAssertNil(state.takeover)
        let focus=state.terminal.focusRequest
        state.updateComposerDraft("/terminal"); state.submitComposerPrompt(); XCTAssertTrue(state.layout.elements.contains(.terminal)); XCTAssertNotEqual(state.terminal.focusRequest,focus)
        let layout=state.layout
        state.updateComposerDraft("/terminal"); state.submitComposerPrompt(); XCTAssertEqual(state.layout,layout); XCTAssertNil(state.terminal.session,"Hidden/unmounted terminal is not duplicated by dispatch")
        var terminateRequests=0; state.requestApplicationTermination={ terminateRequests += 1 }
        state.updateComposerDraft("/quit"); state.submitComposerPrompt(); XCTAssertEqual(terminateRequests,1)
        XCTAssertEqual(backend.sent.count,1); XCTAssertEqual(state.agent.current.attachments,[attachment])
        backend.onEvent?(.started) // A new session preserves this active backend rather than stopping its turn.
        state.updateComposerDraft("/new"); state.submitComposerPrompt()
        XCTAssertNotEqual(state.selectedSession,original); XCTAssertTrue(state.agent.sessions.contains { $0.id == original && $0.state == .running })
        XCTAssertTrue(state.layout.elements.contains(.chat)); XCTAssertFalse(backend.stopped)
        XCTAssertEqual(state.agent.conversations[original]?.attachments,[attachment])
    }
    @MainActor func testMalformedCommandsNeverReachModelAndNormalQueueSteerAttachmentsSurvive() async throws {
        let (state,backend,root)=try fixture()
        for input in ["/new please fix this","/unknown something","/model wrong","/name "] {
            state.updateComposerDraft(input); state.submitComposerPrompt()
            XCTAssertTrue(backend.sent.isEmpty); XCTAssertFalse(state.agent.current.draft.isEmpty)
        }
        let attachment=PromptAttachment(url:root.appendingPathComponent("file.swift"),projectFile:true)
        state.agent.current.attachments=[attachment]
        let prompt="Fix src/views/foo/bar.swift\nSee @file.swift"
        state.updateComposerDraft(prompt); state.submitComposerPrompt()
        try await wait("ordinary send") { backend.sent.count == 1 && !state.agent.pendingActions.contains(state.selectedSession) }
        XCTAssertEqual(backend.sent[0].0.text,prompt); XCTAssertEqual(backend.sent[0].0.attachments,[attachment])
        state.updateComposerDraft("/settings invalid"); state.queueOrSteerComposerPrompt(); XCTAssertEqual(backend.sent.count,1)
        state.updateComposerDraft("normal follow-up"); state.queueOrSteerComposerPrompt()
        try await wait("queue") { backend.sent.count == 2 && !state.agent.pendingActions.contains(state.selectedSession) }
        XCTAssertEqual(backend.sent[1].1,.followUp)
        state.agent.current.queued = .init(text:"frozen queue",attachments:[attachment])
        state.updateComposerDraft("/new"); state.queueOrSteerComposerPrompt()
        try await wait("steer") { backend.steered.count == 1 }
        XCTAssertEqual(backend.steered[0].text,"frozen queue"); XCTAssertEqual(backend.steered[0].attachments,[attachment]); XCTAssertEqual(state.agent.current.draft,"/new")
    }
    @MainActor func testDynamicCommandsPreserveArgumentsAttachmentsAndRefreshRemoval() async throws {
        let (state,backend,root)=try fixture()
        backend.discovered=[.init(name:"custom-command",description:"Custom",source:.extension),.init(name:"my-template",description:nil,source:.prompt),.init(name:"skill:review",description:"Review",source:.skill)]
        state.updateComposerDraft("connect"); state.submitComposerPrompt()
        try await wait("connect") { backend.sent.count == 1 && !state.agent.pendingActions.contains(state.selectedSession) }
        backend.onEvent?(.settled(aborted:false)); state.refreshSlashCommands()
        let attachment=PromptAttachment(url:root.appendingPathComponent("file"),projectFile:false); state.agent.current.attachments=[attachment]
        let original="  /custom-command  alpha  beta\nmore text  "
        state.updateComposerDraft(original); state.submitComposerPrompt()
        try await wait("command dispatch") { backend.sent.count == 2 && !state.agent.pendingActions.contains(state.selectedSession) }
        XCTAssertEqual(backend.sent[1].0.text,String(original.drop(while:\.isWhitespace))); XCTAssertTrue(backend.sent[1].0.attachments.isEmpty)
        XCTAssertEqual(state.agent.current.attachments,[attachment]); XCTAssertEqual(state.agent.current.draft,"")
        state.updateComposerDraft("/"); XCTAssertTrue(state.slashCommands.commands.contains { $0.name == "skill:review" })
        backend.discovered=[]; state.agent.refreshSlashCommands()
        try await wait("catalog removed") { state.agent.slashCommands[state.selectedSession]?.isEmpty == true }
        state.refreshSlashCommands(); XCTAssertFalse(state.slashCommands.commands.contains { $0.action == .agentResource })
        state.updateComposerDraft("/custom-command"); state.submitComposerPrompt(); XCTAssertEqual(backend.sent.count,2); XCTAssertNotNil(state.slashCommands.error)
    }
    @MainActor func testRestartKeepsNewDiscoveryOwnedDespiteLateOldFailure() async throws {
        let (state,backend,_)=try fixture()
        state.updateComposerDraft("connect"); state.submitComposerPrompt()
        try await wait("connect") { backend.sent.count == 1 && !state.agent.pendingActions.contains(state.selectedSession) }
        backend.onEvent?(.settled(aborted:false))
        backend.refreshDelay=60_000_000; backend.refreshFails=true
        state.agent.refreshSlashCommands(); try await wait("old refresh") { backend.refreshCount == 1 }
        backend.discovered=[.init(name:"new-resource",description:"New resource",source:.extension)]
        state.agent.restart()
        try await wait("new backend catalog") { state.agent.slashCommands[state.selectedSession]?.contains(where:{ $0.name == "new-resource" }) == true }
        backend.refreshDelay=180_000_000; backend.refreshFails=false
        state.agent.refreshSlashCommands(); try await wait("new refresh") { backend.refreshCount == 2 }
        try await Task.sleep(nanoseconds:80_000_000)
        XCTAssertTrue(state.agent.slashCommands[state.selectedSession]?.contains(where:{ $0.name == "new-resource" }) == true)
        state.agent.refreshSlashCommands()
        try await Task.sleep(nanoseconds:10_000_000)
        XCTAssertEqual(backend.refreshCount,2,"Old cleanup cannot clear ownership of the newer in-flight request")
        try await Task.sleep(nanoseconds:150_000_000)
        state.agent.refreshSlashCommands(); try await wait("future refresh") { backend.refreshCount == 3 }
    }
    @MainActor func testNativeKeyboardHookPreservesNormalEditingAndModifierKeys() throws {
        let menu=service("/")
        let view=ComposerInput.InputView(); view.handleCommand={ menu.handle($0) }
        func event(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
        }
        view.keyDown(with:event(125)); XCTAssertEqual(menu.selectedID,"resume")
        var completed=""; menu.applyInput={completed=$0}
        view.keyDown(with:event(48,"\t")); XCTAssertEqual(completed,"/resume ")
        menu.synchronize(commands:SlashCommandCatalog.core,input:"/new",session:0,approval:false)
        view.keyDown(with:event(53)); XCTAssertNil(menu.popup)
        var intercepted=0; view.handleCommand={ _ in intercepted += 1; return true }
        view.keyDown(with:event(36,"\r",flags:.shift)); XCTAssertEqual(intercepted,0)
        view.keyDown(with:event(125,"",flags:[.control,.option])); XCTAssertEqual(intercepted,0,"VoiceOver/modified navigation must reach AppKit")
    }
}
