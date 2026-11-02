import Foundation
import Combine
import MilkExtensionHost

/// Pi-specific stock-tool runner on the reusable Milk policy/profile/process boundary.
@MainActor final class PiSandboxExecution {
    @MainActor final class Job {
        let scope: SandboxOperationScope
        let capability = UUID().uuidString
        let tool: String
        var args: JSONValue
        var task: Task<Void, Never>?
        var worker: PiRPCClient?
        var result: CheckedContinuation<JSONValue, Error>?
        var updates: [JSONValue] = []
        var poll: CheckedContinuation<JSONValue, Error>?
        var finished = false
        var admissionEnded = false
        var usedGrants: Set<UUID> = []
        init(scope: SandboxOperationScope, tool: String, args: JSONValue) { self.scope = scope; self.tool = tool; self.args = args }
        func emit(_ value: JSONValue) {
            if let poll { self.poll = nil; poll.resume(returning: value) } else { updates.append(value) }
        }
    }
    let activation: AgentActivation
    let settings: SandboxSettingsStore
    let grants: SandboxGrantStore
    let approvals = SandboxApprovalCenter()
    private let location: PiLaunchContext
    private let roots: SandboxScopeRoots
    private let cache: URL
    private let purpose: AgentBackendPurpose
    private var mode: ComposerPermissionMode
    private var jobs: [String: Job] = [:]
    private var observations: Set<AnyCancellable> = []
    private var closed = false
    var invalidated: (() -> Void)?
    private(set) var effects: SandboxHostEffects!
    private weak var nativeExtensions: NativeExtensionManager?
    private let extensionWorkerExecutable: URL?
    var nativeCatalogURL: URL { cache.appendingPathComponent("native-catalog.json") }
    var event: ((AgentEvent) -> Void)? { didSet { approvals.event = event } }
    var enabled: Bool { settings.configuration.enabled }
    var runtimeTemporaryDirectory: URL { cache }
    static let hostTools: Set<String> = ["milk_git", "milk_job", "native_extension"]
    static let tools: Set<String> = ["read", "write", "edit", "bash", "grep", "find", "ls", "user_bash"]
    init(location: PiLaunchContext, settings: SandboxSettingsStore, grants: SandboxGrantStore,
         activation: AgentActivation, mode: ComposerPermissionMode, purpose: AgentBackendPurpose,
         inactiveProfiles: [SandboxProfileRoot], nativeExtensions: NativeExtensionManager? = nil, extensionWorkerExecutable: URL? = nil) throws {
        self.nativeExtensions=nativeExtensions; self.extensionWorkerExecutable=extensionWorkerExecutable
        self.location = location; self.settings = settings; self.grants = grants; self.activation = activation; self.mode = mode; self.purpose = purpose
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dev.milk/Sandbox/" + activation.token.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        cache = try SandboxPathResolver().resolve(directory).canonicalURL
        let active = SandboxProfileRoot(id: "active:" + location.dataProfile.directory.path, agentID: activation.agentID,
            url: location.dataProfile.directory, ownership: location.dataProfile.ownership == .sharedExisting ? .existing : .managed)
        var known: [SandboxProfileRoot] = []
        for profile in inactiveProfiles where profile.agentID != active.agentID || profile.ownership != active.ownership || profile.url.resolvingSymlinksInPath().path != active.url.resolvingSymlinksInPath().path {
            if !known.contains(where: { $0.ownership == profile.ownership && $0.agentID == profile.agentID && $0.url.resolvingSymlinksInPath().path == profile.url.resolvingSymlinksInPath().path }) { known.append(profile) }
        }
        roots = .init(project: activation.workspace, activeProfile: active, inactiveProfiles: known,
                      writableBuildRoots: [cache])
        effects=try SandboxHostEffects(activation:activation,grants:grants,approvals:approvals,cache:cache,
            context:{ [unowned self] in self.context() },dependencies:{ SandboxProfileBuilder.systemReadRoots },
            mode:{ [unowned self] in self.mode },timeout:{ settings.configuration.autonomousTimeoutSeconds })
        effects.invalidated = { [weak self] in self?.shutdown(); self?.invalidated?() }
        if let nativeExtensions {
            func catalog() { try? nativeExtensions.registry.piCatalogData().write(to:self.nativeCatalogURL,options:.atomic) }
            catalog()
            nativeExtensions.agentWorkersChanged.sink { [weak self, weak nativeExtensions] in
                guard let self, let nativeExtensions else { return }
                try? nativeExtensions.registry.piCatalogData().write(to:self.nativeCatalogURL,options:.atomic)
            }.store(in:&observations)
        }
        let launchPolicy = settings.configuration
        settings.$configuration.dropFirst().sink { [weak self] value in
            var policy = launchPolicy; policy.autonomousTimeoutSeconds = value.autonomousTimeoutSeconds
            if value != policy { self?.shutdown(); self?.invalidated?() }
        }.store(in: &observations)
        grants.$grants.sink { [weak self] values in
            guard let self else { return }; let live = Set(values.map(\.id))
            for job in self.jobs.values where !job.admissionEnded && !job.usedGrants.isSubset(of: live) { self.cancel(job) }
        }.store(in: &observations)
    }
    private func context(_ subject: SandboxSubject = .executor) -> SandboxPolicyContext {
        var result = settings.context(roots: roots, interaction: mode, subject: subject)
        if purpose == .previewInspection {
            result.projectConfiguration.access = .readOnly; result.interaction = .approval
        }
        return result
    }
    private var dependencies: [SandboxProfileBuilder.Root] {
        var roots = purpose == .previewInspection ? SandboxProfileBuilder.probeReadRoots : SandboxProfileBuilder.systemReadRoots
        roots += [location.executable, location.integration, location.integration.deletingLastPathComponent().appendingPathComponent("MilkSandboxBridge.ts"), location.integration.deletingLastPathComponent().appendingPathComponent("MilkSandboxWorker.ts")].map { .init(url: $0, subtree: false) }
        if let closure=location.executableClosure { roots += closure.roots }
        roots += PiRuntimeService.supportRoots(executable:location.executable)
        roots += location.supportPaths.filter { $0.resolvingSymlinksInPath().path != FileManager.default.homeDirectoryForCurrentUser.path }.map { .init(url:$0,subtree:false) }
        return roots
    }
    func runtimeProfile() throws -> String? {
        let profile=try SandboxProfileBuilder().make(context:context(.agentRuntime),dependencies:dependencies)
        return try SandboxProfileBuilder.protectingCode(profile,roots:(location.executableClosure?.roots ?? [])+PiRuntimeService.supportRoots(executable:location.executable))
    }
    func updateMode(_ value: ComposerPermissionMode) { mode = value }
    func handle(_ request: JSONValue) async throws -> JSONValue {
        guard !closed else { throw AgentError.message("Sandbox executor is unavailable for this activation.") }
        if request["kind"].string == "begin" {
            guard let tool = request["tool"].string, (Self.hostTools.contains(tool) || enabled && Self.tools.contains(tool)), jobs.count < 32,
                  purpose != .previewInspection || ["read", "grep", "find", "ls"].contains(tool) else { throw AgentError.message("Unsupported Sandbox execution route.") }
            guard case .object(let arguments) = request["args"] else { throw AgentError.message("Malformed Sandbox tool arguments.") }
            guard arguments["env"] == nil, arguments["environment"] == nil else {
                throw AgentError.message("Caller-supplied execution environments are unsupported. Milk constructs the worker environment.")
            }
            if ["read", "write", "edit"].contains(tool), arguments["path"]?.string?.isEmpty != false { throw SandboxPathError.invalidPath }
            if tool == "write", arguments["content"]?.string == nil { throw AgentError.message("Missing write content.") }
            if tool == "edit" {
                guard let edits = arguments["edits"], !edits.array.isEmpty,
                      edits.array.allSatisfy({ $0["oldText"].string != nil && $0["newText"].string != nil }) else { throw AgentError.message("Missing edit replacements.") }
            }
            let scope = try grants.beginOperation(in: activation)
            let job = Job(scope: scope, tool: tool, args: request["args"])
            jobs[scope.id.uuidString] = job
            job.task = Task { [weak self] in await self?.run(job) }
            return .object(["operation": .string(scope.id.uuidString), "capability": .string(job.capability)])
        }
        let job = try authenticate(request)
        guard request["kind"].string == "next", job.poll == nil else { throw AgentError.message("Invalid or duplicate operation poll.") }
        if !job.updates.isEmpty { return job.updates.removeFirst() }
        guard !job.finished else { throw AgentError.message("Operation already completed.") }
        return try await withCheckedThrowingContinuation { job.poll = $0 }
    }
    private func authenticate(_ value: JSONValue) throws -> Job {
        guard let id = value["operation"].string, let job = jobs[id], value["capability"].string == job.capability else { throw AgentError.message("Stale or unauthenticated Sandbox operation.") }
        return job
    }
    func control(_ value: JSONValue, cancel: Bool) {
        guard let job = try? authenticate(value) else { return }
        if cancel || !job.finished { self.cancel(job) }
        if !cancel { jobs[job.scope.id.uuidString] = nil }
    }
    private func cancel(_ job: Job) {
        job.admissionEnded = true; grants.end(job.scope, reason: .cancelled); job.task?.cancel(); job.worker?.shutdown(); effects.cancel(job.scope)
        job.result?.resume(throwing: CancellationError()); job.result = nil
    }
    func cancelOperations() { approvals.cancelAll(); for job in jobs.values where !job.finished { cancel(job) } }
    func shutdown() { guard !closed else { return }; closed = true; cancelOperations(); effects.shutdown(); grants.invalidate(activation) }
    func shutdownAndWait() async { shutdown(); for job in Array(jobs.values) { await job.task?.value }; await effects.shutdownAndWait(); observations.removeAll(); try? FileManager.default.removeItem(at: cache) }
    func respond(_ request: AgentApproval, response: AgentDialogResponse) throws { try approvals.respond(request, response: response) }
    private func path(_ raw: String) -> URL {
        let home = location.environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return home.appendingPathComponent(String(raw.dropFirst(2))) }
        return raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : activation.workspace.appendingPathComponent(raw)
    }
    private func authorize(_ url: URL, action: SandboxFileAction, job: Job) async throws {
        try Task.checkCancellation()
        let decision = SandboxPolicy().evaluate(url, action: action, context: context())
        let admitted = grants.admitting(decision, operation: job.scope)
        if admitted.outcome == .deny { throw AgentError.message("Sandbox denied \(action.rawValue) access (\(admitted.rule.rawValue)).") }
        if admitted.requiresApproval {
            let lifetime = try await approvals.request(admitted, operation: job.scope, tool: job.tool, command: job.args["command"].string, mode: mode, timeout: settings.configuration.autonomousTimeoutSeconds)
            let current = SandboxPolicy().evaluate(url, action: action, context: context())
            guard current.rule == decision.rule, current.boundaries == decision.boundaries, current.outcome == decision.outcome else { throw CancellationError() }
            try grants.approve(current, access: action == .read ? .readOnly : .readWrite, lifetime: lifetime, operation: job.scope, includesDescendants: current.path?.isDirectory == true)
        }
        job.usedGrants = Set(grants.grants.filter { $0.activation == activation && ($0.operationID == nil || $0.operationID == job.scope.id) }.map(\.id))
    }
    func startManagedJob(_ request: AgentManagedJobRequest) async throws -> AgentManagedJob {
        guard purpose == .conversation, !closed else { throw AgentError.message("This activation cannot start managed jobs.") }
        return try await effects.startManaged(request)
    }
    private func runHost(_ job: Job) async {
        do {
            let output: SandboxHostEffects.Output
            switch job.tool {
            case "milk_git":
                let values=job.args["arguments"].array, arguments=values.compactMap(\.string)
                guard !arguments.isEmpty, arguments.count == values.count else { throw AgentError.message("Git requires structured arguments.") }
                output=try await effects.git(arguments:arguments,scope:job.scope,patch:job.args["patch"].string)
            case "native_extension":
                guard let manager=nativeExtensions, let id=job.args["id"].string else { throw AgentError.message("Native worker contribution is unavailable.") }
                output=try await effects.extensionTool(id:id,arguments:job.args["arguments"],manager:manager,scope:job.scope,helper:extensionWorkerExecutable)
            case "milk_job":
                let action=job.args["action"].string
                if action == "start" {
                    guard let command=job.args["command"].string, let purpose=job.args["purpose"].string.flatMap(AgentManagedJobRequest.Purpose.init(rawValue:)), purpose != .preview else { throw AgentError.message("Managed jobs require a command and watcher/background purpose. Preview owns its separate receipt.") }
                    var folders: [(URL,SandboxFolderAccess)]=[]
                    for entry in job.args["sandboxFolders"].array {
                        guard let raw=entry["path"].string, let access=entry["access"].string.flatMap(SandboxFolderAccess.init(rawValue:)) else { throw SandboxPathError.invalidPath }
                        folders.append((path(raw),access))
                    }
                    let managed=try await startManagedJob(.init(command:command,directory:path(job.args["directory"].string ?? "."),purpose:purpose,folders:folders))
                    if Task.isCancelled { await managed.stop(); throw CancellationError() }
                    output = .init(text:managed.id.uuidString,code:0)
                } else {
                    guard let id=job.args["id"].string.flatMap(UUID.init(uuidString:)), let managed=effects.managed[id] else { throw AgentError.message("No managed job owned by this activation has that ID.") }
                    guard managed.request.purpose != .preview else { throw AgentError.message("Preview owns this job. Use Preview controls to stop or restart it.") }
                    switch action {
                    case "stop": await managed.stop()
                    case "restart": try await managed.restart()
                    case "status": break
                    default: throw AgentError.message("Unsupported managed-job action.")
                    }
                    output = .init(text:managed.state.rawValue+"\n"+managed.output,code:0)
                }
            default: throw AgentError.message("Unsupported host effect.")
            }
            try Task.checkCancellation()
            job.admissionEnded=true; grants.end(job.scope,reason:.finished); job.finished=true
            job.emit(.object(["done":.bool(true),"result":.object(["content":.array([.object(["type":.string("text"),"text":.string(output.text)])]),"details":.object(["exitCode":.number(Double(output.code))]),"isError":.bool(output.code != 0)])]))
        } catch {
            job.admissionEnded=true; effects.cancel(job.scope); job.finished=true
            job.emit(.object(["error":.string(error is CancellationError ? "Operation cancelled." : error.localizedDescription)]))
        }
    }
    private func run(_ job: Job) async {
        if Self.hostTools.contains(job.tool) { await runHost(job); return }
        let worker = PiRPCClient(); job.worker = worker
        do {
            let isCommand = ["bash", "user_bash"].contains(job.tool)
            let target = path(job.args["path"].string ?? ".")
            if isCommand {
                guard let command = job.args["command"].string, !command.isEmpty, command.utf8.count < 128 * 1024 else { throw AgentError.message("Invalid command request.") }
                for folder in job.args["sandboxFolders"].array {
                    guard let raw = folder["path"].string, let access = folder["access"].string.flatMap(SandboxFolderAccess.init(rawValue:)) else { throw SandboxPathError.invalidPath }
                    try await authorize(path(raw), action: access == .readOnly ? .read : .write, job: job)
                }
            } else {
                guard case .object(var args) = job.args else { throw SandboxPathError.invalidPath }
                args["path"] = .string(try SandboxPathResolver().resolve(target).canonicalURL.path); job.args = .object(args)
                try await authorize(target, action: ["write", "edit"].contains(job.tool) ? .write : .read, job: job)
                if job.tool == "edit" { try await authorize(target, action: .read, job: job) }
            }
            try Task.checkCancellation()
            let work = cache.appendingPathComponent(job.scope.id.uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = location.integration.deletingLastPathComponent().appendingPathComponent("MilkSandboxWorker.ts")
            guard FileManager.default.fileExists(atPath: script.path) else { throw AgentError.message("Milk's Sandbox worker is missing. Reinstall Milk.") }
            var c = context(); c.roots.writableBuildRoots.append(work)
            let usable = grants.grants.filter { $0.activation == activation && ($0.operationID == nil || $0.operationID == job.scope.id) }
            job.usedGrants = Set(usable.map(\.id))
            let ordinaryProfile = try SandboxProfileBuilder().make(context: c, dependencies: dependencies, grants: usable,
                admitting: { self.grants.admitting($0, operation: job.scope) })
            let profile=try SandboxProfileBuilder.protectingCode(ordinaryProfile,roots:(location.executableClosure?.roots ?? [])+PiRuntimeService.supportRoots(executable:location.executable))
            let env = PiEnvironment.executor(work:work,support:location.supportPaths,toolchain:location.toolchain)
            var ready = false
            worker.onRecord = { [weak self, weak job] record in
                guard let self, let job, record["type"].string == "extension_ui_request", record["method"].string == "setStatus" else { return }
                let key = record["statusKey"].string
                if key == "milk-worker-ready" { ready = true; return }
                guard let text = record["statusText"].string, let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                if key == "milk-worker-update", !job.finished {
                    if job.updates.count > 128 { self.cancel(job); return }; job.emit(value)
                }
                if key == "milk-worker-result", let continuation = job.result { job.result = nil; continuation.resume(returning: value) }
            }
            worker.onFailure = { [weak job] error in job?.result?.resume(throwing: AgentError.message(error)); job?.result = nil }
            guard location.executableClosure?.revalidated() != false else { throw AgentError.message("Pi worker executable closure changed.") }
            let workerArguments=["--mode", "rpc", "--offline", "--no-session", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "-e", script.path]
            let command=location.executableClosure?.command(workerArguments) ?? (location.executable,workerArguments)
            try worker.launch(executable:command.0,arguments:command.1,workspace:activation.workspace,environment:env,sandboxProfile:profile,sandboxEnabled:enabled)
            let deadline = Date().addingTimeInterval(10)
            while !ready { try Task.checkCancellation(); guard Date() < deadline, worker.isRunning else { throw AgentError.message("Sandbox worker did not become ready. Check its runtime dependencies. " + worker.stderr) }; try await Task.sleep(nanoseconds: 20_000_000) }
            guard case .object(var arguments) = job.args else { throw SandboxPathError.invalidPath }
            arguments["sandboxFolders"] = nil // Milk-only declarations are never passed to upstream factories.
            let payload: JSONValue = .object(["tool": .string(job.tool), "args": .object(arguments)])
            let result = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    job.result = continuation
                    Task { do { _ = try await worker.request("prompt", ["message": .string("/milk-operation " + payload.encodedString)], timeout: 86400) }
                        catch { job.result?.resume(throwing: error); job.result = nil } }
                }
            }, onCancel: { Task { @MainActor [weak self] in self?.cancel(job) } })
            job.admissionEnded = true; grants.end(job.scope, reason: .finished)
            try await worker.shutdownAndWait()
            if let error = result["error"].string { throw AgentError.message(error) }
            job.finished = true; job.emit(.object(["done": .bool(true), "result": result["result"]]))
        } catch {
            job.admissionEnded = true; grants.end(job.scope, reason: Task.isCancelled ? .cancelled : .ended)
            worker.shutdown(); try? await worker.shutdownAndWait()
            job.finished = true; job.emit(.object(["error": .string(error is CancellationError ? "Operation cancelled." : error.localizedDescription)]))
        }
    }
}
