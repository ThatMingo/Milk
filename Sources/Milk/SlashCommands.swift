import AppKit
import Combine
import MilkLayout

/// Source and execution stay explicit: RPC resources are never mistaken for Pi's TUI commands.
struct SlashCommand: Identifiable, Equatable {
    enum Source: Int, Equatable { case milk, milkExtension, agentExtension, prompt, skill
        var label: String? {
            switch self { case .milk: return nil; case .milkExtension: return "Milk Extension"; case .agentExtension: return "Extension"; case .prompt: return "Prompt"; case .skill: return "Skill" }
        }
    }
    enum Arguments: Equatable { case none, required, optional }
    enum Action: Equatable {
        case newSession, resume, name, model, thinking, settings, extensions, terminal, quit
        case nativeExtension, agentResource
    }
    var id: String { name }
    let name: String
    let description: String
    let source: Source
    let arguments: Arguments
    let action: Action
    var unavailable: String? = nil
    var path: String? = nil
}

struct SlashInvocation: Equatable {
    let name: String
    /// Original argument whitespace/content is preserved for Pi; core actions validate their own syntax.
    let arguments: String
    let text: String
    var hasArgumentSeparator: Bool { text.dropFirst(name.count+1).first?.isWhitespace == true }
    static func parse(_ input: String) -> Self? {
        let text=String(input.drop(while: \.isWhitespace))
        guard text.hasPrefix("/") else { return nil }
        let name=String(text.dropFirst().prefix(while:{ !$0.isWhitespace }))
        return .init(name:name,arguments:String(text.dropFirst(name.count+1)),text:text)
    }
    var completionQuery: String? { hasArgumentSeparator ? nil:name }
}

enum ComposerPopup: Equatable { case slash, model, thinking, permissions, references }
enum ComposerKeyCommand: Equatable { case up, down, tab, enter, escape }

/// Pure catalog construction/filtering; a view never contains command execution business logic.
enum SlashCommandCatalog {
    static let core: [SlashCommand] = [
        .init(name:"new",description:"Start a new session",source:.milk,arguments:.none,action:.newSession),
        .init(name:"resume",description:"Browse saved sessions",source:.milk,arguments:.none,action:.resume),
        .init(name:"name",description:"Rename current session",source:.milk,arguments:.required,action:.name),
        .init(name:"model",description:"Select model",source:.milk,arguments:.none,action:.model),
        .init(name:"thinking",description:"Select reasoning effort",source:.milk,arguments:.none,action:.thinking),
        .init(name:"settings",description:"Open Settings",source:.milk,arguments:.none,action:.settings),
        .init(name:"extensions",description:"Open Extensions",source:.milk,arguments:.none,action:.extensions),
        .init(name:"terminal",description:"Show Terminal",source:.milk,arguments:.none,action:.terminal),
        .init(name:"quit",description:"Quit Milk",source:.milk,arguments:.none,action:.quit)
    ]
    static var coreNames: Set<String> { Set(core.map(\.name)) }
    static func validName(_ value: String) -> Bool { !value.isEmpty && !value.contains(where:{ $0.isWhitespace || $0 == "/" || $0.isControlCharacter }) }
    static func merge(core: [SlashCommand], native: [SlashCommand], agent: [AgentCommand]) -> [SlashCommand] {
        var seen=Set<String>()
        let resources=agent.compactMap { item -> SlashCommand? in
            guard let source=item.source else { return nil }
            let kind: SlashCommand.Source
            switch source { case .extension: kind = .agentExtension; case .prompt: kind = .prompt; case .skill: kind = .skill }
            return .init(name:item.name,description:item.description ?? "",source:kind,arguments:.optional,action:.agentResource,path:item.sourceInfo?.path)
        }
        return (core+native+resources.sorted { $0.source.rawValue < $1.source.rawValue }).filter { validName($0.name) && seen.insert($0.name).inserted }
    }
    static func filtered(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let query=query.lowercased()
        guard !query.isEmpty else { return commands }
        // Prefixes lead; substring matching remains inexpensive and predictable.
        return commands.filter { $0.name.lowercased().hasPrefix(query) } + commands.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
    }
}

/// One transient owner coordinates slash completion with the existing composer pickers and approvals.
@MainActor final class SlashCommandService: ObservableObject {
    @Published private(set) var commands: [SlashCommand] = []
    @Published private(set) var results: [SlashCommand] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var popup: ComposerPopup?
    @Published private(set) var error: String?
    @Published private(set) var focusRequest=UUID()
    private(set) var input=""
    private var dismissedInput: String?
    private var session: Int?
    private var approval=false
    var applyInput: ((String) -> Void)?
    var execute: ((SlashCommand,SlashInvocation) -> Void)?
    var refreshResources: (() -> Void)?
    var selected: SlashCommand? { results.first { $0.id == selectedID } }
    var isSlashInput: Bool { SlashInvocation.parse(input) != nil }

    func synchronize(commands: [SlashCommand], input: String, session: Int, approval: Bool) {
        let changedInput=self.input != input, changedSession=self.session != session
        if self.commands != commands { self.commands=commands }
        if changedSession { self.session=session; dismissedInput=nil; error=nil; setPopup(nil) }
        if changedInput { self.input=input; dismissedInput=nil; error=nil }
        self.approval=approval
        if approval {
            dismissedInput=input; setPopup(nil)
        } else if let query=SlashInvocation.parse(input)?.completionQuery {
            let next=SlashCommandCatalog.filtered(commands,query:query)
            if next != results { results=next }
            if !next.contains(where:{ $0.id == selectedID }) { selectedID=next.first?.id }
            if (changedInput || changedSession) && dismissedInput != input { setPopup(.slash) }
        } else {
            if !results.isEmpty { results=[] }; selectedID=nil
            if popup == .slash || changedInput { setPopup(nil) }
        }
    }
    func present(_ value: ComposerPopup?) {
        guard !approval else { dismiss(); return }
        dismissedInput=input
        error=nil; setPopup(value)
    }
    func dismiss() { dismissedInput=input; setPopup(nil) }
    private func setPopup(_ value: ComposerPopup?) {
        guard popup != value else { return }
        popup=value
        if value == .slash { refreshResources?() }
    }
    func highlight(_ id: String) { if results.contains(where:{ $0.id == id }), selectedID != id { selectedID=id } }
    func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        let index=results.firstIndex(where:{ $0.id == selectedID }) ?? 0
        selectedID=results[(index+offset+results.count)%results.count].id
    }
    @discardableResult func handle(_ key: ComposerKeyCommand) -> Bool {
        guard !approval else { return false }
        switch key {
        case .escape:
            guard popup == .slash else { return false }; dismiss(); return true
        case .up, .down:
            guard popup == .slash else { return false }; move(key == .up ? -1:1); return true
        case .tab:
            guard popup == .slash else { return false }; choose(completionOnly:true); return true
        case .enter:
            guard isSlashInput else { return false }
            if popup == .slash { choose(completionOnly:false) } else { _ = submit() }
            return true
        }
    }
    func choose(_ id: String? = nil, completionOnly: Bool = false) {
        if let id { guard results.contains(where:{ $0.id == id }) else { return }; highlight(id) }
        guard let command=selected else { error="No commands found"; return }
        guard command.unavailable == nil else { error=command.unavailable; return }
        if completionOnly || command.arguments != .none {
            let completed="/"+command.name+" "
            applyInput?(completed); input=completed; dismiss(); focusRequest=UUID()
        } else { invoke(command,invocation:.init(name:command.name,arguments:"",text:"/"+command.name)) }
    }
    /// Returns false only for an ordinary prompt. Unknown/malformed slash input never falls through to a model.
    @discardableResult func submit() -> Bool {
        guard let invocation=SlashInvocation.parse(input) else { return false }
        guard !approval else { error="Resolve the pending approval first."; dismiss(); return true }
        guard let command=commands.first(where:{ $0.name == invocation.name }) else { error=invocation.name.isEmpty ? "Choose a command.":"Unknown command: /"+invocation.name; return true }
        if command.arguments == .none && !invocation.arguments.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            error="Usage: /"+command.name; return true
        }
        if command.arguments == .required && invocation.arguments.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let completed="/"+command.name+" "; applyInput?(completed); input=completed; dismiss(); focusRequest=UUID(); return true
        }
        guard command.unavailable == nil else { error=command.unavailable; return true }
        invoke(command,invocation:invocation); return true
    }
    private func invoke(_ command: SlashCommand, invocation: SlashInvocation) { error=nil; dismiss(); execute?(command,invocation) }
    func report(_ message: String) { error=message }
    func focusComposer() { focusRequest=UUID() }
}

private extension Character {
    var isControlCharacter: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}

@MainActor extension ShellState {
    func refreshSlashCommands() {
        var core=SlashCommandCatalog.core
        for index in core.indices {
            switch core[index].action {
            case .newSession: core[index].unavailable=workspace.workspace == nil ? "Open a workspace first.":nil
            case .name: core[index].unavailable=currentSession == nil ? "Choose a session first.":nil
            case .model: core[index].unavailable=availableComposerModels.isEmpty ? "No models reported by Pi yet.":nil
            case .thinking: core[index].unavailable=selectedComposerModel?.efforts.isEmpty != false ? "No reasoning efforts reported by Pi yet.":nil
            default: break
            }
        }
        let native=nativeExtensions.registry.commands.map { SlashCommand(name:$0.item.name,description:$0.item.summary,source:.milkExtension,arguments:.optional,action:.nativeExtension) }
        var catalog=SlashCommandCatalog.merge(core:core,native:native,agent:agent.slashCommands[selectedSession] ?? [])
        for index in catalog.indices where catalog[index].action == .agentResource {
            if agent.busy || agent.pendingActions.contains(selectedSession) { catalog[index].unavailable="Wait for the current Pi action to finish." }
        }
        slashCommands.synchronize(commands:catalog,input:agent.current.draft,session:selectedSession,approval:agent.presentedApproval != nil)
    }
    func updateComposerDraft(_ text: String) {
        agent.current.draft=text
        if SlashInvocation.parse(text) != nil { agent.connectForDiscovery() }
        refreshSlashCommands()
    }
    func presentComposerPopup(_ popup: ComposerPopup?) {
        if popup == .model || popup == .thinking { agent.connectForDiscovery() }
        refreshSlashCommands(); slashCommands.present(popup)
    }
    func queueOrSteerComposerPrompt() {
        if agent.current.queued != nil { agent.queueOrSteer(); return }
        refreshSlashCommands()
        if !slashCommands.submit() { agent.queueOrSteer() }
    }
    func executeSlashCommand(_ command: SlashCommand, invocation: SlashInvocation) {
        let id=selectedSession, original=agent.current.draft
        func consume() { if agent.conversations[id]?.draft == original { agent.conversations[id]?.draft="" }; refreshSlashCommands() }
        switch command.action {
        case .newSession:
            consume(); newSession(); showChat()
        case .resume:
            consume(); takeover=nil; destination="Sessions"; if !sidebarVisible { toggleSidebar() }
        case .name: agent.rename(id,title:invocation.arguments); consume()
        case .model: consume(); presentComposerPopup(.model)
        case .thinking: consume(); presentComposerPopup(.thinking)
        case .settings: consume(); takeover="Settings"
        case .extensions: consume(); takeover="Extensions"
        case .terminal:
            consume(); takeover=nil
            if !layout.elements.contains(.terminal) { change { $0.toggle(.terminal) } }
            terminal.requestFocus()
        case .quit: consume(); requestApplicationTermination()
        case .agentResource: agent.submitSlashCommand(invocation.text,name:command.name)
        case .nativeExtension:
            Task {
                do {
                    guard try await nativeExtensions.executeCommand(command.name,arguments:invocation.arguments.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw AgentError.message("Command is no longer available.") }
                    consume()
                } catch { if selectedSession == id { slashCommands.report(error.localizedDescription) } else { agent.conversations[id]?.notice=error.localizedDescription } }
            }
        }
    }
    private func showChat() { takeover=nil; if !layout.elements.contains(.chat) { change { $0.toggle(.chat) } } }
}
