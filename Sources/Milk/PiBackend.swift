import Foundation
import MilkExtensionHost
import UniformTypeIdentifiers

@MainActor final class PiBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    private let nativeExtensions: NativeExtensionManager?
    private var nativeSession: Int?
    private var nativeTasks: [String:Task<Void,Never>] = [:]
    private let discoveryOnly: Bool
    private let providerProfileIdentityLoader: @MainActor () throws -> String?
    private let providerConfigurationLoader: @MainActor () throws -> PiProviderConfiguration
    private let launchConfiguration: AgentConfiguration
    private let lifecycle: AgentLifecycleCoordinator?
    private let resolveLaunch: @MainActor (PiRuntimeMode, AgentLifecycleCoordinator?) async throws -> PiLaunchContext
    private var resolvedLaunch: PiLaunchContext?
    private var compatibility: AgentCompatibilityResult?
    private let client = PiRPCClient()
    private var workspace: URL?
    private var executable: URL?
    private var version: String?
    private var bundled = true
    private var integrationReady = false
    private var messageDecoder = PiMessageDecoder()
    private var editingApproval: AgentApproval?
    private var activities: [String: AgentActivity] = [:]
    private var dialogs: [String: AgentApproval] = [:]
    private var model: AgentModel?
    private var effort: String?
    private var queuedPayload: [String: JSONValue]?
    private var baseline: AgentFileSnapshot?
    private var snapshotTask: Task<Void, Never>?
    private var runGeneration = UUID()
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private func checkActivation(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == runGeneration else { throw CancellationError() }
    }
    private func schedule(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        maintenanceTasks[id] = Task { [weak self] in
            await work()
            self?.maintenanceTasks[id] = nil
        }
    }
    private func runtimeStatus(_ phase: AgentConnectionPhase, detail: String) -> RuntimeStatus {
        let record = resolvedLaunch?.installation
        let ownership: AgentRuntimeIdentity.Ownership = record?.ownership == .milkManaged ? .milkManaged : (bundled ? .applicationBundle : .external)
        return .init(phase: phase, version: version, bundled: bundled, detail: detail,
                     runtimeIdentity: executable.map { .init(executable: $0, version: version, ownership: ownership, installation: record) }, compatibility: compatibility, dataProfile: resolvedLaunch?.dataProfile)
    }
    init(runtime: PiRuntimeService = PiRuntimeService(), discoveryOnly: Bool = false, nativeExtensions: NativeExtensionManager? = nil,
         configuration: AgentConfiguration = AgentConfiguration(), providerConfiguration: PiProviderConfiguration = .init(), providerConfigurationLoader: (@MainActor () throws -> PiProviderConfiguration)? = nil, providerProfileIdentityLoader: @escaping @MainActor () throws -> String? = { nil }, lifecycle: AgentLifecycleCoordinator? = nil,
         resolveLaunch: (@MainActor (PiRuntimeMode, AgentLifecycleCoordinator?) async throws -> PiLaunchContext)? = nil) {
        self.providerProfileIdentityLoader = providerProfileIdentityLoader
        self.providerConfigurationLoader = providerConfigurationLoader ?? { providerConfiguration }
        self.lifecycle = lifecycle; self.launchConfiguration = configuration; self.discoveryOnly = discoveryOnly; self.nativeExtensions = nativeExtensions
        self.resolveLaunch = resolveLaunch ?? { mode, owner in try await PiLaunchResolver(runtime: runtime).resolve(mode, lifecycle: owner) }
    }

    func start(workspace: URL, session: AgentSession) async throws {
        try await start(workspace: workspace, session: session, configuration: launchConfiguration)
    }
    // Pi-specific entry point retained for direct integration tests and Pi tooling.
    func start(workspace: URL, session: AgentSession, configuration: AgentConfiguration) async throws {
        let token = runGeneration
        self.nativeSession=session.id
        self.workspace = workspace; bundled = configuration.runtime.isBundled
        onEvent?(.runtime(runtimeStatus(.starting, detail: "Starting Pi")))
        do {
            let location = try await resolveLaunch(configuration.runtime, lifecycle)
            try checkActivation(token)
            resolvedLaunch = location; executable = location.executable; version = location.version
            compatibility = location.compatibility; bundled = location.bundled
            var environment = location.environment
            environment["MILK_PERMISSION_MODE"] = configuration.defaultPermission.rawValue
            if discoveryOnly { environment["MILK_PREVIEW_DISCOVERY"] = "1" }
            else { environment.removeValue(forKey: "MILK_PREVIEW_DISCOVERY") }
            // Prevent startup catalog refreshes/self updates; the binary and model capabilities stay versioned.
            environment["PI_OFFLINE"] = "1"
            environment.removeValue(forKey:"MILK_NATIVE_CATALOG")
            if !discoveryOnly, let nativeExtensions { environment["MILK_NATIVE_CATALOG"]=nativeExtensions.catalogURL.path }
            let providerConfiguration = try providerConfigurationLoader()
            try PiProviderSupport.apply(providerConfiguration, directory: location.dataProfile.directory, environment: &environment, profile: providerProfileIdentityLoader())
            var arguments = ["--mode", "rpc", "--offline", "-e", location.integration.path]
            if discoveryOnly {
                arguments += ["--no-session", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--tools", "read,grep,find,ls"]
            } else if let file = session.sessionFile {
                if location.dataProfile.ownership == .milkManaged {
                    let path = URL(fileURLWithPath: file).resolvingSymlinksInPath().path
                    guard path.hasPrefix(location.dataProfile.directory.resolvingSymlinksInPath().path + "/") else {
                        throw AgentError.message("This session belongs to a different Pi profile. Select its original Pi setup to resume it.")
                    }
                }
                guard FileManager.default.fileExists(atPath: file) else { throw AgentError.message("The saved Pi session file is missing. Reopen another session or create one.") }
                arguments += ["--session", file]
            } else { arguments += ["--session-id", session.backendID, "--name", session.title] }
            client.onRecord = { [weak self] in self?.consume($0) }
            client.onFailure = { [weak self] text in
                guard let self else { return }
                self.dismissDialogs(); self.onEvent?(.runtime(self.runtimeStatus(.failed, detail: text)))
                self.onEvent?(.failure(text))
            }
            try client.launch(executable: location.executable, arguments: arguments, workspace: workspace, environment: environment)
            if providerConfiguration.provider == .local, let selected = providerConfiguration.local.selectedModel {
                _ = try await client.request("set_model", ["provider": .string(PiProviderSupport.providerID), "modelId": .string(selected)])
            }
            try await refresh(validatingHandshake: true)
            guard integrationReady else { throw PiCompatibilityPolicy.incompatible(version: version, "Pi did not load Milk's integration extension. This Pi version may be incompatible.") }
            let history = try await client.request("get_messages")
            try PiCompatibilityPolicy.validate("get_messages", reply: history, version: version)
            let messages = history["messages"].array
            try checkActivation(token)
            // No visible clear or item-by-item replay. Native content becomes visible
            // only after the complete, ordered snapshot has been reconstructed.
            let reconstructionMetric = ChatRenderMetrics.begin()
            messageDecoder = PiMessageDecoder(); activities = [:]
            var restored = AgentHistory()
            for (index, message) in messages.enumerated() { restore(message, index: index, into: &restored) }
            ChatRenderMetrics.end("history.reconstruct", reconstructionMetric, units: messages.count)
            onEvent?(.history(restored))
            compatibility = PiCompatibilityPolicy.verified(version: location.version)
            onEvent?(.runtime(runtimeStatus(.ready, detail: "Pi ready")))
        } catch {
            if let error = error as? AgentCompatibilityError { compatibility = error.result; version = error.result.version }
            client.shutdown()
            if token == runGeneration { onEvent?(.runtime(runtimeStatus(.failed, detail: error.localizedDescription))) }
            throw error
        }
    }
    private func refresh(validatingHandshake: Bool = false) async throws {
        let token = runGeneration
        let state = try await client.request("get_state")
        try checkActivation(token)
        if validatingHandshake { try PiCompatibilityPolicy.validate("get_state", reply: state, version: version) }
        model = Self.model(state["model"]); effort = state["thinkingLevel"].string
        onEvent?(.state(.init(sessionFile: state["sessionFile"].string.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, sessionID: state["sessionId"].string, name: state["sessionName"].string, model: model, effort: effort, running: state["isStreaming"].bool || state["isCompacting"].bool)))
        do { try await refreshCommands() }
        catch { try checkActivation(token); if validatingHandshake { throw error }; onEvent?(.slashCommands([])) } // Never retain stale commands after discovery fails.
        let catalog = try await client.request("get_available_models")
        if validatingHandshake { try PiCompatibilityPolicy.validate("get_available_models", reply: catalog, version: version) }
        let models = catalog["models"].array.compactMap(Self.model)
        try checkActivation(token)
        onEvent?(.models(models))
        try await refreshEfforts()
    }
    func refreshCommands() async throws {
        guard !discoveryOnly else { return }
        let token = runGeneration
        let response=try await client.request("get_commands")
        try checkActivation(token)
        try PiCompatibilityPolicy.validate("get_commands", reply: response, version: version)
        let values=response["commands"].array.compactMap(PiCommandDecoder.decode).filter { $0.name != "milk-permission" }
        await nativeExtensions?.reservePiCommands(values.map(\.name))
        try checkActivation(token)
        onEvent?(.slashCommands(values))
    }
    private func refreshEfforts() async throws {
        let token = runGeneration
        let reply = try await client.request("get_available_thinking_levels")
        try PiCompatibilityPolicy.validate("get_available_thinking_levels", reply: reply, version: version)
        let levels = reply["levels"].array.compactMap(\.string)
        try checkActivation(token)
        guard !levels.isEmpty else { throw AgentError.message("Pi returned no model effort capabilities.") }
        onEvent?(.efforts(levels, selected: effort))
    }
    func send(_ prompt: AgentPrompt, intent: AgentSubmissionIntent = .prompt) async throws {
        let payload = try await Self.payload(prompt, model: model)
        if intent == .prompt, let workspace {
            // Serialize the baseline before the prompt can change any project file.
            await snapshotTask?.value
            baseline = try await Task.detached(priority: .utility) { try AgentFileSnapshot.capture(root: workspace) }.value
            if baseline?.limited == true { onEvent?(.notice("Change summary covers nonignored UTF-8 project files up to 1 MB, within a 10,000 file / 64 MB limit.")) }
        }
        var fields = payload
        if intent == .followUp { fields["streamingBehavior"] = .string("followUp") }
        let response = try await client.request("prompt", fields)
        if intent == .followUp { queuedPayload = payload }
        if response["disposition"].string == "handled" { try? await refreshCommands(); onEvent?(.settled(aborted: false)) }
    }
    func clearQueue() async throws { _ = try await client.request("clear_queue"); queuedPayload = nil }
    func steerQueued(_ prompt: AgentPrompt) async throws {
        // Clear the real follow-up queue before re-enqueueing as a real steer.
        // Refuse promotion when something else also owns queue entries.
        guard let payload = queuedPayload else { throw AgentError.message("No queued instruction is available to steer.") }
        let cleared = try await client.request("clear_queue")
        let follow = cleared["followUp"].array.compactMap(\.string)
        let steering = cleared["steering"].array.compactMap(\.string)
        let expected = payload["message"]?.string
        guard steering.isEmpty, follow.count == 1, follow.first == expected else {
            for text in follow { _ = try await client.request("follow_up", ["message": .string(text)]) }
            for text in steering { _ = try await client.request("steer", ["message": .string(text)]) }
            throw AgentError.message("Pi's queue changed before Steer. Its pending messages were restored; try again.")
        }
        do { _ = try await client.request("steer", payload) }
        catch {
            _ = try? await client.request("follow_up", payload)
            throw AgentError.message("Steer failed: \(error.localizedDescription). Check the visible queue before retrying.")
        }
    }
    func stop() async throws {
        try await clearQueue()
        for dialog in Array(dialogs.values) { try respond(dialog, value: nil, confirmed: nil, cancelled: true) }
        _ = try await client.request("abort", timeout: 60)
        for (id, var activity) in activities where activity.status == .running || activity.status == .approval {
            activity.status = .cancelled; activities[id] = activity; onEvent?(.activity(activity))
        }
        onEvent?(.settled(aborted: true))
    }
    func setModel(_ model: AgentModel) async throws {
        _ = try await client.request("set_model", ["provider": .string(model.provider), "modelId": .string(model.modelID)])
        try await refresh()
    }
    func setEffort(_ effort: String) async throws {
        _ = try await client.request("set_thinking_level", ["level": .string(effort)])
        try await refresh()
    }
    func setPermission(_ mode: ComposerPermissionMode) async throws {
        _ = try await client.request("prompt", ["message": .string("/milk-permission \(mode.rawValue)")])
    }
    func rename(_ title: String) async throws {
        _ = try await client.request("set_session_name", ["name": .string(title)])
        onEvent?(.sessionName(title))
    }
    func respond(_ approval: AgentApproval, response: AgentDialogResponse) throws {
        let value: String?, confirmed: Bool?, cancelled: Bool
        switch response {
        case .value(let text): value = text; confirmed = nil; cancelled = false
        case .confirmed(let flag): value = nil; confirmed = flag; cancelled = false
        case .cancelled: value = nil; confirmed = nil; cancelled = true
        }
        var fields: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(approval.id)]
        if cancelled { fields["cancelled"] = .bool(true) }
        if let value { fields["value"] = .string(value) }
        if let confirmed { fields["confirmed"] = .bool(confirmed) }
        try client.write(fields)
        if value == "Edit Command" { editingApproval = approval }
        if let id = approval.activityID, var activity = activities[id] { activity.status = .running; activities[id] = activity; onEvent?(.activity(activity)) }
        dialogs.removeValue(forKey: approval.id); onEvent?(.dismissApproval(approval.id))
    }
    func shutdown() { for task in maintenanceTasks.values { task.cancel() }; maintenanceTasks = [:]; for task in nativeTasks.values { task.cancel() }; nativeTasks=[:]; runGeneration = UUID(); snapshotTask?.cancel(); dismissDialogs(); onEvent = nil; client.onRecord = nil; client.onFailure = nil; client.shutdown() }
    func shutdownAndWait() async throws { shutdown(); try await client.shutdownAndWait() }
    private func dismissDialogs() { editingApproval = nil; for id in dialogs.keys { onEvent?(.dismissApproval(id)) }; dialogs = [:] }

    private static func model(_ value: JSONValue) -> AgentModel? {
        guard let id = value["id"].string, let provider = value["provider"].string else { return nil }
        return .init(provider: provider, modelID: id, name: value["name"].string ?? id, supportsImages: value["input"].array.compactMap(\.string).contains("image"),
                     contextWindow: value["contextWindow"].number.flatMap { $0 > 0 && $0 < Double(Int.max) ? Int($0) : nil },
                     maxTokens: value["maxTokens"].number.flatMap { $0 > 0 && $0 < Double(Int.max) ? Int($0) : nil }, supportsReasoning: value["reasoning"].boolValue)
    }
    private static func payload(_ prompt: AgentPrompt, model: AgentModel?) async throws -> [String: JSONValue] {
        try await Task.detached(priority: .userInitiated) {
            var text = prompt.text, images: [JSONValue] = []
            for attachment in prompt.attachments {
                let url = attachment.url
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 8 * 1024 * 1024 else { throw AgentError.message("Attachment \(url.lastPathComponent) exceeds 8 MB.") }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                if mime.hasPrefix("image/") {
                    guard model?.supportsImages == true else { throw AgentError.message("The active model does not support image attachments.") }
                    guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) else { throw AgentError.message("This image format is not supported by Pi. Use PNG, JPEG, GIF or WebP.") }
                    images.append(.object(["type": .string("image"), "mimeType": .string(mime), "data": .string(data.base64EncodedString())]))
                    text += "\nImage attachment: \(url.lastPathComponent)"
                } else if let content = String(data: data, encoding: .utf8), !content.contains("\0") {
                    // RPC accepts message text/images, not @file CLI arguments. Embed a snapshot explicitly.
                    text += "\n\n<file-reference path=\(JSONValue.string(url.path).encodedString)>\n\(content)\n</file-reference>"
                } else { throw AgentError.message("\(url.lastPathComponent) is not UTF-8 text or a supported image. Pi RPC cannot attach this binary format.") }
            }
            guard text.utf8.count <= 12 * 1024 * 1024 else { throw AgentError.message("Combined file context exceeds 12 MB. Attach fewer files.") }
            var fields: [String: JSONValue] = ["message": .string(text)]
            if !images.isEmpty { fields["images"] = .array(images) }
            return fields
        }.value
    }
    private func restore(_ message: JSONValue, index: Int, into history: inout AgentHistory) {
        let role = message["role"].string ?? ""
        if role == "user" || role == "assistant" {
            let decoded = messageDecoder.restore(message)
            history.messages.append(decoded)
            if role == "assistant" {
                history.error = message["stopReason"].string == "error" ? message["errorMessage"].string ?? "Provider request failed." : nil
                for block in message["content"].array where block["type"].string == "toolCall" {
                    guard let id = block["id"].string else { continue }
                    var activity = makeActivity(id: id, name: block["name"].string ?? "Tool", args: block["arguments"], messageID: decoded.id, restored: true)
                    activity.status = .cancelled // Replaced by the actual saved result when present.
                    activities[id] = activity; history.activities.append(activity)
                }
            }
        } else if role == "toolResult" {
            let id = message["toolCallId"].string ?? "history-tool-\(index)"
            var activity = activities[id] ?? .init(id: id, kind: message["toolName"].string ?? "Tool", detail: "Restored activity", afterMessageID: messageDecoder.currentMessageID)
            activity.output = message["content"].text; activity.status = message["isError"].bool ? .error : .completed
            activities[id] = activity
            if let position = history.activities.firstIndex(where: { $0.id == id && $0.afterMessageID == activity.afterMessageID }) { history.activities[position] = activity }
            else { history.activities.append(activity) }
        }
    }
    private func makeActivity(id: String, name: String, args: JSONValue, messageID: String?, restored: Bool = false) -> AgentActivity {
        let detail = args["command"].string ?? args["path"].string ?? args["pattern"].string ?? args.encodedString
        let kind: String
        switch name {
        case "read": kind = "Read"
        case "grep", "find", "ls": kind = "Search"
        case "edit": kind = "Edit"
        case "write":
            let path = args["path"].string ?? ""
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace?.appendingPathComponent(path)
            kind = restored ? "Write" : (url.map { FileManager.default.fileExists(atPath: $0.path) } == true ? "Edit" : "Create")
        case "bash": kind = detail.range(of: "\\b(build|test|xcodebuild)\\b", options: .regularExpression) != nil ? "Build" : "Command"
        default: kind = name
        }
        return .init(id: id, kind: kind, detail: detail, afterMessageID: messageID)
    }
    private func consume(_ record: JSONValue) {
        switch record["type"].string {
        case "agent_start": onEvent?(.started)
        case "agent_settled":
            dismissDialogs()
            onEvent?(.settled(aborted: record["aborted"].bool))
            if let workspace, let before = baseline {
                baseline = nil
                let token = runGeneration
                snapshotTask = Task { [weak self] in
                    do {
                        let after = try await Task.detached(priority: .utility) { try AgentFileSnapshot.capture(root: workspace) }.value
                        guard !Task.isCancelled, let self, self.runGeneration == token else { return }
                        self.onEvent?(.changes(before.changes(to: after)))
                    } catch {
                        guard !Task.isCancelled, let self, self.runGeneration == token else { return }
                        self.onEvent?(.notice("File change summary failed: \(error.localizedDescription)"))
                    }
                }
            }
            let token = runGeneration
            schedule { [weak self] in
                do { try await self?.refresh() }
                catch { guard let self, self.runGeneration == token, !Task.isCancelled else { return }; self.onEvent?(.failure(error.localizedDescription)) }
            }
        case "turn_start", "turn_end", "message_start", "message_update", "message_end":
            for event in messageDecoder.consume(record) { onEvent?(event) }
        case "tool_execution_start":
            let id = record["toolCallId"].string ?? UUID().uuidString
            let activity = makeActivity(id: id, name: record["toolName"].string ?? "Tool", args: record["args"], messageID: messageDecoder.currentMessageID)
            activities[id] = activity; onEvent?(.activity(activity))
        case "tool_execution_update", "tool_execution_end":
            guard let id = record["toolCallId"].string, var activity = activities[id] else { return }
            let ended = record["type"].string == "tool_execution_end"
            let result = record[ended ? "result" : "partialResult"]
            let output = result["content"].text
            activity.output = (output.count > 200000 ? "Earlier output omitted from this activity view.\n" : "") + String(output.suffix(200000))
            if let path = result["details"]["fullOutputPath"].string { activity.output += "\nFull output: " + path }
            if ended { activity.status = record["isError"].bool ? .error : .completed; activity.duration = record["durationMs"].number.map { $0 / 1000 } ?? Date().timeIntervalSince(activity.started) }
            activities[id] = activity; onEvent?(.activity(activity))
        case "queue_update":
            func texts(_ v: JSONValue) -> [String] { v.array.map { $0.string ?? $0["content"].text } }
            onEvent?(.queue(followUp: texts(record["followUp"]), steering: texts(record["steering"])))
        case "session_info_changed": if let name = record["name"].string { onEvent?(.sessionName(name)) }
        case "thinking_level_changed":
            effort = record["level"].string
            schedule { [weak self] in try? await self?.refreshEfforts() }
        case "extension_ui_request": handleUI(record)
        case "extension_error":
            let text="\(record["extensionPath"].string ?? "Pi extension"): \(record["error"].string ?? "Unknown extension error")"
            onEvent?(.extensionProblem(text)); onEvent?(.notice(text))
        case "auto_retry_start": onEvent?(.notice("Provider retry \(Int(record["attempt"].number ?? 0)): \(record["errorMessage"].string ?? "")"))
        case "auto_retry_end":
            if record["success"].bool { onEvent?(.retrySucceeded) }
            else { onEvent?(.failure(record["finalError"].string ?? "Provider retries failed.")) }
        case "compaction_start": onEvent?(.notice("Pi is compacting the session context."))
        case "compaction_end":
            if let error = record["errorMessage"].string { onEvent?(.failure(error)) }
            onEvent?(.notice(record["aborted"].bool ? "Pi context compaction cancelled." : record["errorMessage"].string == nil ? "Pi context compacted." : "Pi context compaction failed."))
        default: break // Version-compatible unknown events are ignored, malformed framing is fatal.
        }
    }
    private func handleUI(_ value: JSONValue) {
        let method = value["method"].string ?? ""
        if method == "input", let text=value["title"].string, let data=text.data(using:.utf8),
           let request=try? JSONDecoder().decode(JSONValue.self,from:data), request["milkNativeBridge"].number == 1, let id=value["id"].string {
            nativeTasks[id]=Task { [weak self] in
                guard let self else { return }
                defer { self.nativeTasks[id]=nil }
                let result: JSONValue
                do {
                    guard let manager=self.nativeExtensions, let workspace=self.workspace, let session=self.nativeSession else { throw AgentError.message("Native extension bridge is unavailable.") }
                    let output: String
                    if let prompt=request["prompt"].string { output=try manager.piPrompt(prompt,workspace:workspace) }
                    else if let toolID=request["contribution"].string { output=try await manager.invokePiTool(id:toolID,arguments:Data(request["arguments"].encodedString.utf8),workspace:workspace,session:session) }
                    else { throw AgentError.message("Invalid native bridge request.") }
                    result = .object(["result":.string(output)])
                } catch { result = .object(["error":.string(error.localizedDescription)]) }
                if !Task.isCancelled { try? self.client.write(["type":.string("extension_ui_response"),"id":.string(id),"value":.string(result.encodedString)]) }
            }
            return
        }
        if method == "setStatus" {
            switch value["statusKey"].string {
            case "milk-integration-ready": integrationReady = value["statusText"].string == "1"
            case "milk-command-edit":
                if let text = value["statusText"].string, let data = text.data(using: .utf8),
                   let detail = try? JSONDecoder().decode(JSONValue.self, from: data), let id = detail["activityID"].string,
                   var activity = activities[id] {
                    activity.detail = detail["command"].string ?? activity.detail; activities[id] = activity; onEvent?(.activity(activity))
                }
            case "milk-session-dir": if let path = value["statusText"].string { onEvent?(.sessionDirectory(URL(fileURLWithPath: path))) }
            default: break
            }
        } else if ["select", "confirm", "input", "editor"].contains(method), let id = value["id"].string {
            var request = AgentApproval(id: id, method: AgentDialogMethod(rawValue: method)!, title: value["title"].string ?? "Pi request", message: value["message"].string ?? "", options: value["options"].array.compactMap(\.string), prefill: value["prefill"].string ?? value["placeholder"].string ?? "", timeout: value["timeout"].number)
            if let detail = request.title.data(using: .utf8).flatMap({ try? JSONDecoder().decode(JSONValue.self, from: $0) }), detail["milkApproval"].number == 1 {
                request.origin = .agentPermission
                request.activityID = detail["activityID"].string
                request.tool = detail["tool"].string
                request.action = detail["action"].string
                request.command = request.tool == "bash" ? detail["action"].string : nil
                request.workingDirectory = detail["cwd"].string
                request.reason = detail["reason"].string
                request.effect = detail["effect"].string
                request.risk = detail["risk"].string
                request.title = "Approval required · \(request.tool ?? "Tool")"
                request.message = [request.action, request.workingDirectory, request.reason, request.effect].compactMap { $0 }.joined(separator: "\n\n")
            } else if method == "editor", let parent = editingApproval {
                request.origin = parent.origin
                request.title = parent.title; request.activityID = parent.activityID
                request.tool = parent.tool; request.action = parent.action; request.command = parent.command
                request.workingDirectory = parent.workingDirectory; request.reason = parent.reason
                request.effect = parent.effect; request.risk = parent.risk
                editingApproval = nil
            }
            dialogs[id] = request
            if let activityID = request.activityID, var activity = activities[activityID] { activity.status = .approval; activities[activityID] = activity; onEvent?(.activity(activity)) }
            onEvent?(.approval(request))
            if let timeout = request.timeout {
                let token = runGeneration
                schedule { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000))
                    guard !Task.isCancelled, self?.runGeneration == token else { return }
                    if self?.dialogs.removeValue(forKey: id) != nil { self?.onEvent?(.dismissApproval(id)) }
                }
            }
        } else if method == "notify", let message = value["message"].string { onEvent?(value["notifyType"].string == "error" ? .failure(message) : .notice(message)) }
    }
}
