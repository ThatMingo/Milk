import SwiftUI
import MilkCore

public struct ChatPane: View {
    @Bindable var session: PiSessionController
    let piPath: String
    @State private var dialogText = ""
    public init(session: PiSessionController, piPath: String) { self.session = session; self.piPath = piPath }
    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if session.messages.isEmpty { Text("Start a conversation with Pi in this workspace.").foregroundStyle(.secondary).padding(.top, 24) }
                        ForEach(session.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "You" : "Pi").font(.caption.bold()).foregroundStyle(.secondary)
                                if message.text.utf16.count > 4000 || message.text.filter({ $0 == "\n" }).count > 100 {
                                    LongTranscriptText(text: message.text).frame(height: 320)
                                } else {
                                    Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(12).background(message.role == "user" ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(session.tools) { tool in
                            DisclosureGroup {
                                Text(tool.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if !tool.output.isEmpty { Text(tool.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            } label: { Label(tool.name + (tool.finished ? (tool.failed ? " · failed" : " · done") : " · pending/running"), systemImage: "wrench.and.screwdriver") }
                        }
                        ForEach(session.widgets.keys.sorted(), id: \.self) { key in Text(session.widgets[key, default: []].joined(separator: "\n")).font(.caption) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }.onChange(of: session.messages.count) { reader.scrollTo("bottom", anchor: .bottom) }
            }
            if let error = session.error { HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { session.error = nil } }.padding(8) }
            if let dialog = session.dialogs.first { dialogView(dialog) }
            Divider()
            NativeComposer(text: $session.composer).frame(minHeight: 85, idealHeight: 115, maxHeight: 190)
            HStack {
                Picker("Permission mode", selection: Binding(get: { session.record.mode }, set: { mode in Task { await session.setMode(mode) } })) {
                    Text("Approval").tag(AgentMode.approval); Text("Autonomous").tag(AgentMode.autonomous)
                }.frame(width: 220).disabled(session.running)
                if session.pendingCount > 0 { Text("\(session.pendingCount) queued").font(.caption) }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { Task { await session.stop() } }.disabled(!session.running)
                Button(session.running ? "Queue Follow-up" : "Send", systemImage: "arrow.up") { Task { await session.send(piPath: piPath) } }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(8)
        }
    }
    @ViewBuilder private func dialogView(_ dialog: ExtensionDialog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dialog.title).font(.headline).textSelection(.enabled)
            if !dialog.message.isEmpty { Text(dialog.message).textSelection(.enabled) }
            if ["input", "editor"].contains(dialog.method) { TextEditor(text: $dialogText).frame(height: 90).onAppear { dialogText = dialog.prefill } }
            HStack {
                if dialog.method == "select" { ForEach(dialog.options, id: \.self) { option in Button(option) { Task { await session.respond(dialog, value: option) } } } }
                else if dialog.method == "confirm" { Button("Confirm") { Task { await session.respond(dialog, confirmed: true) } } }
                else { Button("Submit") { Task { await session.respond(dialog, value: dialogText) } } }
                Button("Cancel") { Task { await session.respond(dialog) } }
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
    }
}

/// Long streamed messages use viewport-based TextKit layout instead of a single enormous SwiftUI Text.
private struct LongTranscriptText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .systemFont(ofSize: 14); view.textColor = .textColor
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Long Pi response")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let current = view.string
        if text.hasPrefix(current), let storage = view.textStorage {
            let suffix = (text as NSString).substring(from: current.utf16.count)
            storage.append(NSAttributedString(string: suffix, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
        } else { view.string = text }
    }
}
