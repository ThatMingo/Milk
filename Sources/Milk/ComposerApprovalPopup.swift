import SwiftUI
import AppKit

struct PresentedAgentApproval: Identifiable {
    var session: Int
    var request: AgentApproval
    var waitingForEditor = false
    var id: String { request.id }
}
extension AgentService {
    /// Background sessions retain their approval tab indicator; selecting them reveals their popup.
    var presentedApproval: PresentedAgentApproval? {
        if let request = approvals[selectedSession]?.first { return .init(session: selectedSession, request: request) }
        if let request = editingApprovals[selectedSession] { return .init(session: selectedSession, request: request, waitingForEditor: true) }
        return nil
    }
}

struct ComposerApprovalPopup: View {
    @ObservedObject var agent: AgentService
    let presentation: PresentedAgentApproval
    let maximumHeight: CGFloat
    @State private var value = ""
    @State private var contentHeight: CGFloat = 120
    @State private var surfaceHeight: CGFloat = 240
    private var request: AgentApproval { presentation.request }
    private var editing: Bool { request.method == .editor }
    private var knownAction: Bool { request.tool != nil }
    var body: some View {
        ScrollView { form }
            .frame(height: min(surfaceHeight, max(70, maximumHeight)))
            .background(MilkTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(MilkTheme.line))
            .onAppear { value = request.prefill }
            .onChange(of: request.id) { _, _ in value = request.prefill }
            .accessibilityIdentifier("milk.approval.surface")
    }
    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(request.command != nil ? "Pi wants to run a command" : request.title, systemImage: "hand.raised")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if let risk = request.risk, !risk.isEmpty { Text(risk).font(.system(size: 10, weight: .medium)).foregroundStyle(MilkTheme.red) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if editing {
                        TextEditor(text: $value).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                            .padding(6).frame(height: 74).background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityLabel("Edit command").accessibilityIdentifier("milk.approval.command.editor")
                    } else if let command = request.command {
                        HStack(alignment: .top, spacing: 8) {
                            Text("$").foregroundStyle(MilkTheme.muted)
                            Text(command).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 12, design: .monospaced)).padding(10)
                            .background(MilkTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    } else if let action = request.action, !action.isEmpty {
                        Text(action).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    if let directory = request.workingDirectory, !directory.isEmpty { metadata("In", value: (directory as NSString).abbreviatingWithTildeInPath) }
                    if let reason = request.reason, !reason.isEmpty { metadata("Why", value: reason) }
                    if let effect = request.effect, !effect.isEmpty { metadata("Effect", value: effect) }
                    if !knownAction && !request.message.isEmpty { Text(request.message).font(.system(size: 12)).textSelection(.enabled) }
                    if request.method == .input { TextField("Value", text: $value).textFieldStyle(.roundedBorder) }
                    if presentation.waitingForEditor { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Opening command editor…").font(.system(size: 11)).foregroundStyle(MilkTheme.muted) } }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }.frame(height: min(contentHeight, 210))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { secondaryActions.fixedSize(); Spacer(minLength: 12); primaryActions.fixedSize() }
                VStack(spacing: 8) {
                    HStack(spacing: 8) { secondaryActions; Spacer(minLength: 0) }
                    HStack(spacing: 8) { Spacer(minLength: 0); primaryActions }
                }
            }.disabled(presentation.waitingForEditor)
        }.padding(12).foregroundStyle(MilkTheme.ink).fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { surfaceHeight = $0 }
    }
    private func metadata(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(MilkTheme.muted).frame(width: 36, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11.5))
    }
    @ViewBuilder private var secondaryActions: some View {
        Button(editing ? "Cancel" : "Deny") { agent.respond(request, session: presentation.session, cancelled: true) }
            .buttonStyle(MilkButtonStyle(bordered: true)).accessibilityLabel(editing ? "Cancel edited command" : "Deny").accessibilityIdentifier(editing ? "milk.approval.cancel-edit" : "milk.approval.deny")
        if request.options.contains("Edit Command") && !editing {
            Button("Edit Command…") { agent.respond(request, session: presentation.session, value: "Edit Command") }
                .buttonStyle(MilkButtonStyle()).accessibilityLabel("Edit Command").accessibilityIdentifier("milk.approval.edit")
        }
    }
    @ViewBuilder private var primaryActions: some View {
        if editing || request.method == .input {
            Button(editing ? "Allow edited command" : "Submit") { agent.respond(request, session: presentation.session, value: value) }
                .buttonStyle(MilkButtonStyle(bordered: true)).accessibilityIdentifier("milk.approval.run").disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if request.method == .confirm {
            Button("Allow Once") { agent.respond(request, session: presentation.session, confirmed: true) }.buttonStyle(MilkButtonStyle(bordered: true))
        } else {
            ForEach(request.options.filter { $0 != "Deny" && $0 != "Edit Command" && $0 != "Allow Once" }, id: \.self) { option in
                Button(option == "Allow for Session" ? "For session" : option) { agent.respond(request, session: presentation.session, value: option) }
                    .buttonStyle(MilkButtonStyle()).accessibilityLabel(option)
            }
            if request.options.contains("Allow Once") {
                Button("Allow Once") { agent.respond(request, session: presentation.session, value: "Allow Once") }.buttonStyle(MilkButtonStyle(bordered: true))
            }
        }
    }
}

/// A nonmodal child window follows the composer in screen coordinates. It never takes a modal
/// session, dims the app, dismisses on outside clicks, or participates in conversation scrolling.
struct ComposerApprovalAnchor: NSViewRepresentable {
    @ObservedObject var agent: AgentService
    let maximumHeight: CGFloat
    var visible = true
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(); anchor.identifier = NSUserInterfaceItemIdentifier("milk.geometry.composer")
        return anchor
    }
    func updateNSView(_ anchor: Anchor, context: Context) {
        let coordinator = context.coordinator
        anchor.reposition = { [weak coordinator, weak anchor] in if let anchor { coordinator?.position(anchor) } }
        if visible, let presentation = agent.presentedApproval {
            coordinator.content = { width in AnyView(ComposerApprovalPopup(agent: agent, presentation: presentation, maximumHeight: maximumHeight).frame(width: width).fixedSize(horizontal: false, vertical: true)) }
            coordinator.show(anchor)
        } else { coordinator.close() }
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: Coordinator) { coordinator.close() }
    final class Anchor: NSView {
        var reposition: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); reposition?() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reposition?() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); reposition?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reposition?() }
    }
    final class Panel: NSPanel { override var canBecomeKey: Bool { true } }
    final class Host: NSHostingView<AnyView> {
        var didLayout: (() -> Void)?
        override func layout() { super.layout(); didLayout?() }
    }
    final class Coordinator {
        var content: ((CGFloat) -> AnyView)?
        private var panel: Panel?
        private var host: Host?
        private var observers: [NSObjectProtocol] = []
        private weak var parent: NSWindow?
        private weak var anchor: Anchor?
        private var lastWidth: CGFloat = 0
        private var positioning = false
        func show(_ anchor: Anchor) {
            self.anchor = anchor
            if panel == nil {
                let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.identifier = NSUserInterfaceItemIdentifier("milk.approval.popup")
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
                panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
                panel.appearance = nil
                let host = Host(rootView: AnyView(EmptyView()))
                host.didLayout = { [weak self, weak anchor] in
                    DispatchQueue.main.async { if let anchor { self?.position(anchor) } }
                }
                panel.contentView = host; self.panel = panel; self.host = host
            }
            lastWidth = 0 // Refresh content while preserving the same native panel through edit handoff.
            position(anchor)
        }
        func position(_ anchor: Anchor) {
            guard !positioning, let window = anchor.window, let panel, let host, anchor.bounds.width > 1 else { return }
            positioning = true; defer { positioning = false }
            if parent !== window {
                observers.forEach(NotificationCenter.default.removeObserver); observers = []
                parent = window
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak anchor] _ in if let anchor { self?.position(anchor) } })
                }
            }
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if abs(lastWidth - rect.width) > 0.1 {
                lastWidth = rect.width
                host.rootView = content?(rect.width) ?? AnyView(EmptyView())
            }
            let size = host.fittingSize
            let frame = NSRect(x: rect.minX, y: rect.maxY + 14, width: rect.width, height: max(1, size.height))
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
            if !panel.isVisible { panel.orderFront(nil) }
        }
        func close() {
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            host?.didLayout = nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil; host = nil; parent = nil; lastWidth = 0
        }
        deinit { close() }
    }
}
