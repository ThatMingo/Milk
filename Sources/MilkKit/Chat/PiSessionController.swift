import Foundation
import Observation
import MilkCore
import AppKit

public struct ChatMessage: Identifiable, Sendable {
    public let id: UUID
    public var role: String
    public var text: String
    public init(id: UUID = UUID(), role: String, text: String) { self.id = id; self.role = role; self.text = text }
}
public struct ToolActivity: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public var output = ""
    public var finished = false
    public var failed = false
}
public struct ExtensionDialog: Identifiable, Sendable {
    public let id: String
    public let method: String
    public let title: String
    public let message: String
    public let options: [String]
    public let prefill: String
}

@MainActor @Observable public final class PiSessionController: Identifiable {
    public nonisolated let id: UUID
    public var record: SessionRecord
    public private(set) var messages: [ChatMessage] = []
    public private(set) var tools: [ToolActivity] = []
    public private(set) var dialogs: [ExtensionDialog] = []
    public private(set) var status = "Not started"
    public private(set) var running = false
    public private(set) var connected = false
    public private(set) var provider = ""
    public private(set) var model = ""
    public private(set) var pendingCount = 0
    public private(set) var bridgeReady = false
    public var composer = ""
    public var error: String?
    public var extensionStatus: [String: String] = [:]
    public var widgets: [String: [String]] = [:]
    @ObservationIgnored public var changed: (@MainActor () -> Void)?
    @ObservationIgnored private var client: PiClient?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var currentAssistant: UUID?
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let folder: URL
    public init(record: SessionRecord, folder: URL) { self.id = record.id; self.record = record; self.folder = folder }

    public func start(piPath: String? = nil) async throws {
        if connected { return }
        guard !starting else { throw MilkError.message("Pi is already starting") }
        starting = true; status = "Starting Pi"; error = nil; defer { starting = false }
        do {
            let installation = try await PiDiscovery.discover(path: piPath)
            var env = installation.environment; env["MILK_AGENT_MODE"] = record.mode.rawValue
            var args = ["--mode", "rpc", "--extension", PiDiscovery.companionURL.path]
            if let decision = try projectTrust() { args.append(decision ? "--approve" : "--no-approve") }
            if let file = record.file {
                guard FileManager.default.fileExists(atPath: file) else { throw MilkError.message("Saved Pi session is missing. Create a new session; this association was preserved.") }
                args += ["--session", file]
            } else { args += ["--session-id", record.id.uuidString.lowercased()] }
            let client = PiClient(); self.client = client
            eventsTask = Task { [weak self] in for await event in client.events { await self?.consume(event) } }
            try await client.start(.init(executable: installation.executable, arguments: args, directory: folder, environment: env))
            applyState(try await client.request("get_state"))
            let history = try await client.request("get_messages")
            messages = history["messages"].array.compactMap(Self.message)
            _ = try await client.request("prompt", fields: ["message": .string("/milk-bridge")])
            for _ in 0..<100 { if bridgeReady { break }; try await Task.sleep(for: .milliseconds(50)) }
            guard bridgeReady else { throw MilkError.message("Milk’s Pi permission bridge did not acknowledge readiness. Prompting is disabled.") }
            connected = true; status = "Idle"; changed?()
        } catch {
            await client?.shutdown(); self.client = nil; connected = false; status = "Error"; self.error = error.localizedDescription; throw error
        }
    }
    public func send(piPath: String? = nil) async {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
        error = nil
        do {
            try await start(piPath: piPath)
            guard bridgeReady, let client else { throw MilkError.message("Pi bridge is unavailable") }
            var fields: [String: JSONValue] = ["message": .string(text)]
            if running { fields["streamingBehavior"] = .string("followUp") }
            let result = try await client.request("prompt", fields: fields)
            composer = ""
            if result["disposition"].string == "started" { running = true; status = "Running" }
        } catch { self.error = error.localizedDescription }
    }
    public func stop() async {
        do {
            for dialog in dialogs { try await client?.send(["type": .string("extension_ui_response"), "id": .string(dialog.id), "cancelled": .bool(true)]) }
            dialogs.removeAll(); status = "Stopping"
            try await client?.stop(); running = false; status = connected ? "Idle" : "Stopped"
        } catch { self.error = error.localizedDescription }
    }
    public func respond(_ dialog: ExtensionDialog, value: String? = nil, confirmed: Bool? = nil) async {
        var fields: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(dialog.id)]
        if let value { fields["value"] = .string(value) } else if let confirmed { fields["confirmed"] = .bool(confirmed) } else { fields["cancelled"] = .bool(true) }
        do { try await client?.send(fields); dialogs.removeAll { $0.id == dialog.id } }
        catch { self.error = error.localizedDescription }
    }
    public func setMode(_ mode: AgentMode) async {
        guard !running, !starting else { error = "Stop the session before changing permission mode"; return }
        await shutdown(); record.mode = mode; changed?()
    }
    public func shutdown() async {
        for dialog in dialogs { await respond(dialog) }
        await client?.shutdown(); client = nil; eventsTask?.cancel(); eventsTask = nil
        flushTask?.cancel(); flushText()
        connected = false; running = false; bridgeReady = false; status = "Stopped"; changed?()
    }
    private func applyState(_ state: JSONValue) {
        provider = state["model"]["provider"].string ?? "Unavailable"
        model = state["model"]["id"].string ?? "No model selected"
        if let file = state["sessionFile"].string { record.file = file }
        if let name = state["sessionName"].string { record.name = name }
        running = state["isStreaming"].bool == true || state["isCompacting"].bool == true
    }
    private func consume(_ event: PiEvent) async {
        switch event {
        case .diagnostic: break
        case .failed(let message): error = message; status = "Protocol error"
        case .exited(let code): connected = false; running = false; bridgeReady = false; dialogs.removeAll(); status = "Stopped (\(code))"
        case .record(let record): await consumeRecord(record)
        }
    }
    private func consumeRecord(_ value: JSONValue) async {
        switch value["type"].string {
        case "agent_start": running = true; status = "Running"
        case "agent_settled":
            running = false; status = "Idle"; currentAssistant = nil
            if let client, let state = try? await client.request("get_state") { applyState(state); changed?() }
        case "message_start":
            if value["message"]["role"].string == "assistant" { let message = ChatMessage(role: "assistant", text: ""); currentAssistant = message.id; messages.append(message) }
            else if let message = Self.message(value["message"]), message.role == "user" { messages.append(message) }
        case "message_update":
            let update = value["assistantMessageEvent"]
            if update["type"].string == "text_delta" {
                pendingText += update["delta"].string ?? ""
                if flushTask == nil {
                    flushTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled else { return }
                        self?.flushText(); self?.flushTask = nil
                    }
                }
            }
        case "message_end":
            flushTask?.cancel(); flushTask = nil; flushText()
            if let message = Self.message(value["message"]), message.role == "assistant" {
                if let id = currentAssistant, let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text = message.text } else { messages.append(message) }
                currentAssistant = nil
                if value["message"]["stopReason"].string != "aborted", let failure = value["message"]["errorMessage"].string { error = failure }
            }
        case "tool_execution_start":
            tools.append(.init(id: value["toolCallId"].string ?? UUID().uuidString, name: value["toolName"].string ?? "Tool", arguments: value["args"].description))
        case "tool_execution_update", "tool_execution_end":
            if let index = tools.firstIndex(where: { $0.id == value["toolCallId"].string }) {
                let finished = value["type"].string == "tool_execution_end"
                tools[index].output = String((finished ? value["result"] : value["partialResult"]).description.prefix(20_000))
                tools[index].finished = finished; tools[index].failed = value["isError"].bool == true
            }
        case "queue_update": pendingCount = value["steering"].array.count + value["followUp"].array.count
        case "compaction_start": status = "Compacting"
        case "auto_retry_start": status = "Retrying"
        case "extension_error": error = "Pi extension reported an error during \(value["event"].string ?? "execution")"
        case "extension_ui_request":
            let method = value["method"].string ?? ""
            let id = value["id"].string ?? ""
            if ["select", "confirm", "input", "editor"].contains(method) {
                dialogs.append(.init(id: id, method: method, title: value["title"].string ?? "Pi extension", message: value["message"].string ?? "", options: value["options"].array.compactMap(\.string), prefill: value["prefill"].string ?? ""))
            } else if method == "setStatus", let key = value["statusKey"].string {
                extensionStatus[key] = value["statusText"].string
                if key == "milk.bridge", value["statusText"].string == "ready:1:" + record.mode.rawValue { bridgeReady = true }
            } else if method == "setWidget", let key = value["widgetKey"].string { widgets[key] = value["widgetLines"].array.compactMap(\.string) }
            else if method == "set_editor_text" { composer = value["text"].string ?? "" }
            else if method == "notify" { status = value["message"].string ?? status }
            else if method == "setTitle", let name = value["title"].string { record.name = name; changed?() }
        default: break
        }
    }
    private static func message(_ value: JSONValue) -> ChatMessage? {
        guard let role = value["role"].string, ["user", "assistant"].contains(role) else { return nil }
        let text = value["content"].string ?? value["content"].array.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
        return ChatMessage(role: role, text: text)
    }
    private func flushText() {
        if let id = currentAssistant, let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += pendingText }
        pendingText = ""
    }
    private func projectTrust() throws -> Bool? {
        let protected = [".pi/settings.json", ".pi/mcp.json", ".pi/extensions", ".pi/skills", ".pi/prompts", ".pi/themes", ".pi/SYSTEM.md", ".pi/APPEND_SYSTEM.md", ".agents/skills"]
        guard protected.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { return nil }
        let key = "pi.projectTrust." + folder.resolvingSymlinksInPath().path
        if let saved = UserDefaults.standard.object(forKey: key) as? Bool { return saved }
        let alert = NSAlert(); alert.messageText = "Load this workspace’s Pi resources?"
        alert.informativeText = "Project Pi extensions and configuration may execute code. This decision is separate from tool approvals and is stored only by Milk."
        alert.addButton(withTitle: "Trust Workspace"); alert.addButton(withTitle: "Use Global Pi Resources"); alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        guard result != .alertThirdButtonReturn else { throw MilkError.message("Pi launch cancelled") }
        let trusted = result == .alertFirstButtonReturn; UserDefaults.standard.set(trusted, forKey: key); return trusted
    }
}
