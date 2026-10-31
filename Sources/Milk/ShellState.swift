import SwiftUI
import AppKit
import MilkLayout
import Combine
import MilkExtensionKit
import MilkExtensionHost

@MainActor final class ShellState: ObservableObject {
    @Published var layout = WorkspaceLayout() { didSet { persist(); if !changingLayout { resizeWindow?(nil,false) } } }
    @Published var isEditingLayout = false { didSet { resizeWindow?(nil,true) } }
    @Published private(set) var sidebarWidth: CGFloat = MilkTheme.defaultSidebarWidth
    @Published private(set) var sidebarVisible = true
    var sidebarExtent: CGFloat { sidebarVisible ? sidebarWidth + 1 : 0 }
    var shellHeight: CGFloat { MilkTheme.topHeight + MilkTheme.statusHeight + (isEditingLayout ? 44 : 0) }
    private var changingLayout=false
    var resizeWindow: ((CGSize?, Bool)->Void)?
    let settings: SettingsService
    let updates: UpdateService
    let nativeExtensions: NativeExtensionManager
    private var nativeObservation: AnyCancellable?
    let extensions: ExtensionService
    private var gitPreferencesObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    let workspace: WorkspaceStore
    let agent: AgentService
    let agentInstallations: PiInstallationManager
    let preview: PreviewService
    let terminal: TerminalService
    private var terminalObservation: AnyCancellable?
    private var previewObservation: AnyCancellable?
    private var workspaceObservation: AnyCancellable?
    private var agentObservation: AnyCancellable?
    private var gitObservation: AnyCancellable?
    var sessions: [AgentSession] { get { agent.sessions } set { agent.sessions = newValue } }
    var selectedSession: Int { get { agent.selectedSession } set { agent.selectForBrowsing(newValue) } }
    var currentSession: AgentSession? { agent.currentSession }
    var activityState: AgentSession.State { currentSession?.state ?? .idle }
    var taskLabel: String { agent.statusLabel }
    var availableComposerModels: [ComposerModel] { agent.composerModels }
    var selectedComposerModel: ComposerModel? { availableComposerModels.first { $0.id == agent.current.modelID } }
    var selectedComposerEffort: ComposerEffort? { selectedComposerModel?.efforts.first { $0.id == agent.current.effort } }
    var permissionMode: ComposerPermissionMode { get { agent.current.permission } set { agent.setPermission(newValue) } }
    var approvalMode: Bool { get { permissionMode == .approval } set { permissionMode = newValue ? .approval : .autonomous } }
    @Published var sessionExpanded: [Int:Bool] = [:]
    @Published var sessionOutputExpanded: [Int:Bool] = [:]
    let slashCommands=SlashCommandService()
    private var slashObservation: AnyCancellable?
    // Schedule the normal selector on AppKit's run loop, outside Swift tasks/GCD blocks,
    // so terminateLater can dispatch its existing asynchronous process-cleanup callbacks.
    var requestApplicationTermination: () -> Void = { NSApp.perform(#selector(NSApplication.terminate(_:)),with:nil,afterDelay:0) }
    func submitComposerPrompt() {
        refreshSlashCommands()
        if !slashCommands.submit() { agent.submit() }
    }
    func selectComposerModel(_ id: String) { agent.selectModel(id) }
    func selectComposerEffort(_ id: String) { agent.selectEffort(id) }
    @Published var destination = "Files" { didSet { workspace.schedulePersistence() } }
    @Published var runtimeConfigurationVisible = false
    @Published var settingsSelection="General"
    @Published var extensionsSelection="Installed"
    @Published var takeover: String? { didSet { resizeWindow?(nil,false) } }
    // Data-driven destinations leave room for extension-contributed entries.
    var sidebarDestinations: [SidebarDestination] { [SidebarDestination(id:"Files",icon:"folder"), SidebarDestination(id:"Sessions",icon:"bubble.left.and.bubble.right"), SidebarDestination(id:"Git",icon:"point.3.connected.trianglepath.dotted")] + nativeExtensions.registry.sidebar.map { SidebarDestination(id:$0.id,icon:$0.item.systemImage,title:$0.item.title,badge:$0.item.badge) } }
    var panelElements: [WorkspaceElement] { WorkspaceElement.allCases + nativeExtensions.registry.panels.compactMap { WorkspaceElement(rawValue:$0.id) } }
    var renderedRoot: LayoutNode? { layout.root?.available { element in !element.isExtension || nativeExtensions.registry.panels.contains(where:{ $0.id == element.rawValue }) } }
    var sessionAttention: AgentSession.State? {
        [.error, .approval, .unread, .running].first { status in sessions.contains { $0.state == status } }
    }

    @Published var requestedGridSize: CGSize = .zero
    var gridSize = CGSize.zero
    // Retain the original key so existing user layouts continue to migrate.
    private let persistenceKey = "Milk.sample-workspace.layout.v2"
    private var persistenceEnabled: Bool
    private let preferences: UserDefaults
    init(persist: Bool = !CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") }), preferences: UserDefaults = .standard, backendFactory: (@MainActor () -> AgentBackend)? = nil, agentAdapter: (any AgentAdapter)? = nil, previewServers: DevServerService? = nil, terminalService: TerminalService? = nil, extensionService: ExtensionService? = nil, nativeExtensionManager: NativeExtensionManager? = nil) {
        self.preferences=preferences
        settings=SettingsService(defaults:preferences,persist:persist)
        updates=UpdateService(defaults:preferences)
        extensions=extensionService ?? ExtensionService()
        let native=nativeExtensionManager ?? NativeExtensionManager(root:persist ? nil:FileManager.default.temporaryDirectory.appendingPathComponent("MilkExtensionTests-"+UUID().uuidString))
        nativeExtensions=native
        workspace=WorkspaceStore(persistence:WorkspacePersistence(defaults:preferences,enabled:persist))
        let owner = AgentLifecycleCoordinator()
        let installationRoot: URL? = persist ? nil : FileManager.default.temporaryDirectory.appendingPathComponent("MilkInstallations-" + UUID().uuidString)
        let installations = PiInstallationManager(store: AgentInstallationStore(root: installationRoot), lifecycle: owner)
        // Migrate code selection before restoring any workspace. This never probes,
        // downloads or copies a legacy runtime and leaves provider preferences alone.
        try? installations.migrateLegacySelection(AgentConfiguration.load(preferences).runtime)
        agentInstallations = installations
        agent=AgentService(workspace:workspace,defaults:preferences,enabled:persist,adapter:agentAdapter ?? AgentRegistry.standard(defaults:preferences,nativeExtensions:native,installations:installations).defaultAdapter,makeBackend:backendFactory,lifecycle:owner)
        installations.prepareForShutdown = { [weak agent] in try agent?.prepareForInstallationChange() }
        installations.sessionRuntimeVersions = { [weak agent] in Set(agent?.sessions.filter { $0.agentID == .pi }.compactMap { $0.metadata.lastRuntimeVersion } ?? []) }
        installations.onSelectionChanged = { [weak agent, weak extensions] in agent?.objectWillChange.send(); extensions?.refresh(workspace: nil) }
        extensions.lifecycle = agent.lifecycle
        extensions.installations = installations
        extensions.runtimeSelection = { [weak agent] in agent?.configuration.runtime ?? .bundled }
        preview=PreviewService(defaults:preferences,persist:persist,devServers:previewServers)
        terminal=terminalService ?? TerminalService()
        persistenceEnabled = persist
        if persist, let prefs=preferences.dictionary(forKey:"Milk.sidebar.v1") {
            sidebarWidth=min(420,max(180,prefs["width"] as? Double ?? 248))
            sidebarVisible=prefs["visible"] as? Bool ?? true
        }
        if persist, let data=preferences.data(forKey:persistenceKey), let value=try? JSONDecoder().decode(WorkspaceLayout.self,from:data), Set(value.elements).count == value.elements.count { layout=value }
        workspaceObservation=workspace.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        gitObservation=workspace.git.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        workspace.layoutData={ [weak self] in self.flatMap { try? JSONEncoder().encode($0.layout) } }
        agentObservation=agent.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in self?.refreshSlashCommands() }
        }
        slashObservation=slashCommands.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        slashCommands.applyInput={ [weak self] text in self?.updateComposerDraft(text) }
        slashCommands.execute={ [weak self] command,invocation in self?.executeSlashCommand(command,invocation:invocation) }
        slashCommands.refreshResources={ [weak agent] in agent?.refreshSlashCommands() }
        native.registry.reservedCommands.formUnion(SlashCommandCatalog.coreNames)
        workspace.sessionData={ [weak self] in self?.agent.snapshot() }
        workspace.restoreSessionData={ [weak self] data in self?.agent.restore(data) }
        previewObservation=preview.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        terminalObservation=terminal.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        nativeObservation=native.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        native.focusSidebar={ [weak self] id in self?.destination=id; if self?.sidebarVisible == false { self?.toggleSidebar() }; self?.takeover=nil }
        native.authorize={ [weak self] owner,action,root,session in
            guard let self else { throw CancellationError() }
            if self.agent.sessions.isEmpty { self.agent.newSession() }
            self.takeover=nil
            if !self.layout.elements.contains(.chat) { self.change { $0.toggle(.chat) } }
            try await self.agent.authorizeExtensionAction(owner:owner,action:action,workspace:root,session:session)
        }
        native.onContributionsChanged={ [weak self] in
            guard let self else { return }
            WorkspaceElement.extensionDescriptors=Dictionary(uniqueKeysWithValues:self.nativeExtensions.registry.panels.map { ($0.id,.init(title:$0.item.title,minimum:$0.item.minimumSize)) })
            if !self.sidebarDestinations.contains(where:{ $0.id == self.destination }) { self.destination="Files" }
            if self.settingsSelection.hasPrefix("extension:"), !self.nativeExtensions.registry.settings.contains(where:{ $0.id == self.settingsSelection }) { self.settingsSelection="General" }
            self.refreshSlashCommands()
            self.objectWillChange.send(); self.resizeWindow?(nil,false)
        }
        workspace.onFilesChanged={ [weak native] in native?.notifyWorkspaceFilesChanged() }
        workspace.onChangeWorkspace={ [weak self] root in
            self?.preview.setWorkspace(root)
            self?.terminal.setWorkspace(root)
            Task { await self?.nativeExtensions.setWorkspace(root) }
        }
        preview.selectedHTML={ [weak self] in
            guard let file=self?.workspace.activeBuffer?.url, ["html","htm"].contains(file.pathExtension.lowercased()) else { return nil }; return file
        }
        preview.authorize={ [weak self] config in
            guard let self else { throw CancellationError() }
            if self.agent.sessions.isEmpty { self.agent.newSession() }
            if self.agent.current.permission == .approval {
                self.takeover=nil
                if !self.layout.elements.contains(.chat) { self.change { $0.toggle(.chat) } }
            }
            return try await self.agent.authorizePreview(config)
        }
        preview.assist={ [weak self] root in
            guard let self else { throw CancellationError() }
            return try await self.agent.discoverPreview(root:root)
        }
        preview.onActivity={ [weak self] id,output,status in self?.agent.recordPreviewActivity(id:id,output:output,status:status) }
        agent.onExtensionProblem={ [weak self] text in self?.extensions.reportRuntimeProblem(text) }
        workspace.git.sideBySide=settings.gitSideBySide
        gitPreferencesObservation=settings.$gitSideBySide.dropFirst().sink { [weak git=workspace.git] value in git?.sideBySide=value }
        workspace.onCloseWorkspace={ [weak self] in self?.agent.workspaceClosed() }
        workspace.sidebarDestination={ [weak self] in self?.destination ?? "Files" }
        workspace.restoreLayout={ [weak self] data,destination in
            guard let self else { return }
            if let data,let saved=try? JSONDecoder().decode(WorkspaceLayout.self,from:data),Set(saved.elements).count == saved.elements.count {
                self.change({ $0=saved },preserve:false)
            }
            self.destination=self.sidebarDestinations.contains(where: { $0.id == destination }) ? destination : "Files"
            self.selectedSession=self.workspace.selectedSession
        }
        workspace.onOpenFile={ [weak self] in
            guard let self else { return }
            if !self.layout.elements.contains(.code) { self.change { $0.toggle(.code) } }
        }
        preview.defaultDevice=settings.previewDevice
        settingsObservation=settings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preview.defaultDevice=self.settings.previewDevice
            }
        }
        if persist && settings.restoreWorkspace { workspace.restoreActiveWorkspace() }
        if persist { Task { await native.start() } }
        refreshSlashCommands()
    }
    func persist() {
        if persistenceEnabled, workspace.workspace == nil, let data=try? JSONEncoder().encode(layout) { preferences.set(data,forKey:persistenceKey) }
        workspace.schedulePersistence()
    }
    func change(_ edit: (inout WorkspaceLayout)->Void, preserve: Bool = true) {
        let old=layout
        let allocation=CGSize(width:max(gridSize.width,old.minimumWidth),height:max(gridSize.height,old.minimumHeight))
        let frames=old.root?.frames(in:CGRect(origin:.zero,size:allocation)) ?? [:]
        var sizes: [WorkspaceElement:CGSize]=[:]
        for e in old.elements { if let id=old.root?.leaf(for:e) { sizes[e]=frames[id]?.size } }
        var next=layout; edit(&next)
        if let root=next.root {
            requestedGridSize=root.preferred(sizes)
            // Explicit saved-layout restore can retain saved ratios; other edits
            // derive allocations from the current rendered leaf dimensions.
            if preserve { next.root=root.preserving(sizes) }
        } else { requestedGridSize=CGSize(width:180,height:300) }
        changingLayout=true
        layout=next
        changingLayout=false
        resizeWindow?(requestedGridSize,true)
    }
    func applyPreset(_ preset: LayoutPreset) { change { $0.apply(preset) } }
    func toggleSidebar() {
        let workspace=gridSize
        sidebarVisible.toggle(); saveSidebar()
        resizeWindow?(workspace,true)
    }
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth=min(420,max(180,width)); saveSidebar()
        // The user is dragging a separator: retain the frame unless a panel
        // minimum requires more room. No animation during pointer resizing.
        resizeWindow?(nil,false)
    }
    private func saveSidebar() {
        if persistenceEnabled { preferences.set(["width":sidebarWidth,"visible":sidebarVisible],forKey:"Milk.sidebar.v1") }
    }

    func newSession() { agent.newSession() }
    func closeSession(_ id: Int) { agent.closeSession(id) }
    var minimumWindowSize: CGSize {
        if takeover != nil { return CGSize(width:takeover == "Extensions" ? 1160:860,height:640) }
        // Collapsed-sidebar toolbar: 470 pt controls + 76 pt traffic-light reserve
        // + horizontal breathing room. Retain the normal panel minimums otherwise.
        let contentWidth=renderedRoot == nil ? CGFloat(470+76+32):renderedRoot!.minimum.width
        return CGSize(width:sidebarExtent+contentWidth,
               height:(renderedRoot?.minimum.height ?? 300)+MilkTheme.topHeight+MilkTheme.statusHeight+(isEditingLayout ? 44:0))
    }
}

struct SidebarDestination: Identifiable {
    let id: String
    let icon: String
    var title: String? = nil
    var badge: String? = nil
}
