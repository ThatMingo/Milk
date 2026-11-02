import Foundation
import Combine
import MilkExtensionHost
import MilkExtensionKit
import Darwin

@MainActor final class SandboxHostEffects {
    struct Output { let text: String; let code: Int32 }
    let activation: AgentActivation
    let grants: SandboxGrantStore
    let approvals: SandboxApprovalCenter
    let context: () -> SandboxPolicyContext
    let dependencies: () -> [SandboxProfileBuilder.Root]
    let mode: () -> ComposerPermissionMode
    let timeout: () -> Double
    let cache: URL
    let gitHome: URL
    var repository: SandboxGitRepository?
    var invalidated: (() -> Void)?
    var closed = false
    var processes: [UUID:[SandboxProcess]] = [:]
    var managed: [UUID:AgentManagedJob] = [:]
    private var scopeGrants: [UUID:(SandboxOperationScope,Set<UUID>)] = [:]
    private var observations: Set<AnyCancellable> = []
    init(activation: AgentActivation, grants: SandboxGrantStore, approvals: SandboxApprovalCenter, cache: URL,
         gitHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         context: @escaping () -> SandboxPolicyContext, dependencies: @escaping () -> [SandboxProfileBuilder.Root],
         mode: @escaping () -> ComposerPermissionMode, timeout: @escaping () -> Double) throws {
        self.activation=activation; self.grants=grants; self.approvals=approvals; self.cache=cache; self.gitHome=gitHome
        self.context=context; self.dependencies=dependencies; self.mode=mode; self.timeout=timeout
        repository = try? SandboxGitRepository.discover(at:activation.workspace,home:gitHome)
        grants.$grants.sink { [weak self] values in
            guard let self else { return }; let live=Set(values.map(\.id))
            for (id,(scope,required)) in Array(self.scopeGrants) where !required.isSubset(of:live) || !self.grants.isLive(scope) {
                self.scopeGrants[id]=nil
                // Published emits before assignment; defer mutations of the grant store until it completes.
                Task { self.cancel(scope) }
            }
            for job in self.managed.values where !job.usedGrants.isSubset(of:live) || job.scope.map({ !self.grants.isLive($0) }) == true { Task { await self.stop(job) } }
        }.store(in:&observations)
    }
    func check(_ scope: SandboxOperationScope) throws {
        try Task.checkCancellation()
        guard !closed, grants.isLive(scope), scope.activation == activation else { throw CancellationError() }
    }
    @discardableResult func authorize(_ url: URL, action: SandboxFileAction, scope: SandboxOperationScope,
                                     tool: String, command: String, subject: SandboxSubject = .executor) async throws -> Bool {
        try check(scope)
        var policy = context(); policy.subject = subject
        let decision = SandboxPolicy().evaluate(url,action:action,context:policy)
        let admitted = grants.admitting(decision,operation:scope)
        guard admitted.outcome != .deny else { throw AgentError.message("Sandbox denied \(action.rawValue) access (\(admitted.rule.rawValue)).") }
        if admitted.requiresApproval {
            let explanation = tool == "Git" ? "Execute this exact real-Git operation outside the normal filesystem sandbox. Configured hooks/helpers/editor helpers share this explicit trust exception." : tool == "Managed job" ? "Start an explicit owned job until Stop or session/project/runtime shutdown. Once permissions last for this job lifetime." : "Run this tool in the separate sandbox worker."
            let lifetime = try await approvals.request(admitted,operation:scope,tool:tool,command:command,mode:mode(),timeout:timeout(),effect:explanation)
            try check(scope)
            var currentContext = context(); currentContext.subject = subject
            let current = SandboxPolicy().evaluate(url,action:action,context:currentContext)
            guard current.rule == decision.rule, current.outcome == decision.outcome, current.boundaries == decision.boundaries else { throw CancellationError() }
            try grants.approve(current,access:action == .read ? .readOnly : .readWrite,lifetime:lifetime,operation:scope,includesDescendants:current.path?.isDirectory == true)
            return true
        }
        return false
    }
    func usable(_ scope: SandboxOperationScope, subject: SandboxSubject = .executor) -> [SandboxTemporaryGrant] {
        grants.grants.filter { $0.activation == activation && $0.subject == subject && ($0.operationID == nil || $0.operationID == scope.id) }
    }
    func profile(_ scope: SandboxOperationScope, subject: SandboxSubject = .executor, extra: [SandboxProfileBuilder.Root] = [], readOnly: Bool = false, purposeDependencies: [SandboxProfileBuilder.Root]? = nil) throws -> String? {
        try check(scope); var c = context(); c.subject=subject
        if readOnly { c.projectConfiguration.access = .readOnly }
        let used=usable(scope,subject:subject)
        let previous=scopeGrants[scope.id]?.1 ?? []
        scopeGrants[scope.id]=(scope,previous.union(used.map(\.id)))
        return try SandboxProfileBuilder().make(context:c,dependencies:(purposeDependencies ?? dependencies())+extra,grants:used,admitting:{ self.grants.admitting($0,operation:scope) })
    }
    func run(executable: URL, arguments: [String], directory: URL, environment: [String:String], profile: String?, scope: SandboxOperationScope, input: Data? = nil) async throws -> Output {
        try check(scope)
        let command = SandboxProfileBuilder.command(executable:executable,arguments:arguments,profile:profile)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let process = try SandboxProcess(executable:command.0,arguments:command.1,directory:directory,environment:environment,input:stdin,output:stdout,errors:stderr)
        processes[scope.id,default:[]].append(process)
        let writer = Task.detached { if let input { try? stdin.fileHandleForWriting.write(contentsOf:input) }; try? stdin.fileHandleForWriting.close() }
        let error = Task.detached { var bytes=Data(); while true { let chunk=process.read(stderr.fileHandleForReading); if chunk.isEmpty { break }; if bytes.count < 8*1024*1024 { bytes.append(chunk) } }; return bytes }
        let read = Task.detached { var bytes=Data(); while true { let chunk=process.read(stdout.fileHandleForReading); if chunk.isEmpty { break }; if bytes.count < 8*1024*1024 { bytes.append(chunk) } }; process.waitUntilExit(); return bytes }
        return try await withTaskCancellationHandler(operation:{
            let output = await read.value; let errors = await error.value; _ = await writer.value
            processes[scope.id]?.removeAll { $0 === process }; try check(scope)
            return .init(text:String(decoding:output+errors,as:UTF8.self),code:process.terminationStatus)
        },onCancel:{ process.terminate() })
    }
    func git(arguments: [String], scope: SandboxOperationScope, patch: String? = nil) async throws -> Output {
        let operation = try SandboxGitCommand.recognize(arguments)
        guard (arguments.first == "apply") == (patch != nil), (patch?.utf8.count ?? 0) <= 2*1024*1024 else { throw AgentError.message("Only cached Git apply accepts a bounded structured patch on stdin.") }
        try check(scope)
        guard let expected = repository, expected.problem == nil, expected.revalidated(),
              let current = try SandboxGitRepository.discover(at:activation.workspace,home:gitHome),
              current.root.canonicalURL == expected.root.canonicalURL,
              current.gitDirectory.canonicalURL == expected.gitDirectory.canonicalURL,
              current.commonDirectory.canonicalURL == expected.commonDirectory.canonicalURL,
              current.configurationDigest == expected.configurationDigest else { throw AgentError.message("Git repository/control configuration changed or is unsupported. Reconnect before requesting Git escalation.") }
        if operation.writes && context().projectConfiguration.access == .readOnly { throw AgentError.message("Project Read Only blocks agent Git mutations.") }
        let display = "git " + arguments.map { JSONValue.string($0).encodedString }.joined(separator:" ")
        var prompted = try await authorize(current.root.canonicalURL,action:operation.writes ? .write : .read,scope:scope,tool:"Git",command:display)
        for path in current.controls where path.exists {
            let metadataWrite = operation.writes && (path.canonicalURL == current.gitDirectory.canonicalURL || path.canonicalURL == current.commonDirectory.canonicalURL)
            if try await authorize(path.canonicalURL,action:metadataWrite ? .write : .read,scope:scope,tool:"Git",command:display) { prompted = true }
        }
        // Bulk Git operations may touch any worktree file. Stronger nested roots
        // still require their own policy decision; repo-root permission is insufficient.
        let policy=context(), root=current.root
        let boundaries=policy.configuration.protectedLocations.map(\.url)+policy.roots.inactiveProfiles.map(\.url) +
            (policy.configuration.globalAllowedFolders+policy.projectConfiguration.allowedFolders).map(\.url)
        for url in boundaries {
            let path=try SandboxPathResolver().resolve(url)
            if root.contains(path) || path.contains(root) {
                if try await authorize(path.canonicalURL,action:operation.writes ? .write : .read,scope:scope,tool:"Git",command:display) { prompted=true }
            }
        }
        // Explicit paths are literal (never Git magic); canonical aliases cannot bypass policy.
        var paths=false
        for argument in arguments.dropFirst() {
            if argument == "--" { paths=true; continue }
            if (paths || ["add","restore","rm"].contains(arguments[0])) && !argument.hasPrefix("-") {
                if try await authorize(root.canonicalURL.appendingPathComponent(argument),action:operation.writes ? .write : .read,scope:scope,tool:"Git",command:display) { prompted=true }
            }
        }
        // Canonical identities are checked using real Git inside the normal filesystem sandbox.
        let work = cache.appendingPathComponent("git-"+scope.id.uuidString)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var env = SandboxEnvironment.execution(home:gitHome,temporary:work,support:[])
        env["GIT_OPTIONAL_LOCKS"]="0"; env["GIT_TERMINAL_PROMPT"]="0"; env["TERM"]="dumb"
        let metadata = current.controls.map { SandboxProfileBuilder.Root(url:$0.canonicalURL,subtree:$0.isDirectory) }
        let preflight = try await run(executable:URL(fileURLWithPath:"/usr/bin/git"),arguments:["--no-pager","rev-parse","--path-format=absolute","--show-toplevel","--absolute-git-dir","--git-common-dir"],directory:current.root.canonicalURL,environment:env,profile:profile(scope,extra:metadata),scope:scope)
        let identityPaths = preflight.text.split(separator:"\n").map { String($0) }
        guard preflight.code == 0, identityPaths.count == 3 else { throw AgentError.message("Git could not validate its repository inside the normal sandbox. No elevated retry was used.") }
        let canonical = try identityPaths.map { try SandboxPathResolver().resolve(URL(fileURLWithPath:$0)).canonicalURL }
        guard canonical == [current.root.canonicalURL,current.gitDirectory.canonicalURL,current.commonDirectory.canonicalURL] else { throw AgentError.message("Git worktree/gitdir identity is ambiguous. No escalation was used.") }
        let readOnly = context().projectConfiguration.access == .readOnly
        if !prompted && !readOnly { try await approvals.action(operation:scope,tool:"Git",command:display,effect:"Execute this exact real-Git operation outside the normal filesystem sandbox. Configured Git hooks/helpers/editor helpers share this explicit trust exception.",mode:mode()) }
        try check(scope)
        guard let checked = try SandboxGitRepository.discover(at:activation.workspace,home:gitHome), checked.configurationDigest == current.configurationDigest, checked.revalidated() else { throw CancellationError() }
        // These are host-owned compatibility controls, never caller-supplied GIT_* overrides.
        if !readOnly { env.removeValue(forKey:"GIT_OPTIONAL_LOCKS") }
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], socket.hasPrefix("/"), !socket.utf8.contains(0),
           let path=try? SandboxPathResolver().resolve(URL(fileURLWithPath:socket)), path.finalIdentity?.kind == S_IFSOCK,
           path.revalidated() { env["SSH_AUTH_SOCK"]=path.canonicalURL.path }
        let result = try await run(executable:URL(fileURLWithPath:"/usr/bin/git"),arguments:["--no-pager","--literal-pathspecs"]+arguments,directory:current.root.canonicalURL,environment:env,profile:readOnly ? profile(scope,extra:metadata) : nil,scope:scope,input:patch.map { Data($0.utf8) })
        if let fresh = try SandboxGitRepository.discover(at:activation.workspace,home:gitHome), Set(fresh.controls.map { $0.canonicalURL.path }) == Set(current.controls.map { $0.canonicalURL.path }) { repository=fresh }
        else { closed=true; invalidated?() }
        return result
    }
    func cancel(_ scope: SandboxOperationScope) { grants.end(scope,reason:.cancelled); for process in processes[scope.id] ?? [] { process.terminate() } }
    func shutdown() {
        closed=true
        for job in managed.values { if let scope=job.scope { grants.end(scope,reason:.cancelled) }; job.process?.terminate(); if job.state == .running { job.state = .stopping } }
        for group in processes.values { for process in group { process.terminate() } }
    }
    func shutdownAndWait() async {
        shutdown()
        for job in Array(managed.values) { await job.completion?.value }
        for group in Array(processes.values) { for process in group { await Task.detached { process.waitUntilExit() }.value } }
    }
    func startManaged(_ request: AgentManagedJobRequest, owner: String? = nil) async throws -> AgentManagedJob {
        guard !closed, managed.values.filter({ [.starting,.running,.stopping].contains($0.state) }).count < 16 else { throw AgentError.message("Managed job limit reached or activation ended.") }
        let job=AgentManagedJob(activation:activation,request:request,owner:owner)
        job.stopAction = { [weak self, weak job] in if let self, let job { await self.stop(job) } }
        job.restartAction = { [weak self, weak job] in guard let self, let job else { throw CancellationError() }; await self.stop(job); try await self.launch(job) }
        managed[job.id]=job
        do { try await launch(job); return job } catch { job.state = .failed; throw error }
    }
    private func launch(_ job: AgentManagedJob) async throws {
        guard managed[job.id] === job, !closed, !job.request.command.isEmpty, job.request.command.utf8.count <= 128*1024 else { throw CancellationError() }
        let generation=job.nextGeneration(), scope=try grants.beginOperation(in:activation)
        job.scope=scope; job.state = .starting; job.usedGrants=[]; job.output=""
        do {
            let directory=try SandboxPathResolver().resolve(job.request.directory)
            guard directory.isDirectory else { throw SandboxPathError.invalidPath }
            var prompted=try await authorize(directory.canonicalURL,action:.read,scope:scope,tool:"Managed job",command:job.request.command)
            for (url,access) in job.request.folders {
                if try await authorize(url,action:access == .readOnly ? .read : .write,scope:scope,tool:"Managed job",command:job.request.command) { prompted=true }
            }
            if !prompted { try await approvals.action(operation:scope,tool:"Managed job",command:job.request.command,effect:"Start an explicit \(job.request.purpose.rawValue) job until Stop or owner/session/project/runtime shutdown. Once permissions belong to this job's lifetime.",mode:mode()) }
            try check(scope); guard generation == job.generation else { throw CancellationError() }
            let work=cache.appendingPathComponent("job-"+job.id.uuidString+"-"+generation.uuidString)
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // cache is a host-owned writable build root, never caller-selected HOME/TMP.
            let env=SandboxEnvironment.execution(home:work,temporary:work,support:[])
            let sbpl=try profile(scope)
            let command=SandboxProfileBuilder.command(executable:URL(fileURLWithPath:"/bin/bash"),arguments:["-c",job.request.command],profile:sbpl)
            let input=Pipe(), output=Pipe(), errors=Pipe()
            let process=try SandboxProcess(executable:command.0,arguments:command.1,directory:directory.canonicalURL,environment:env,input:input,output:output,errors:errors)
            try? input.fileHandleForWriting.close()
            job.process=process; job.profile=sbpl; job.usedGrants=Set(usable(scope).map(\.id)); job.state = .running
            func reader(_ handle: FileHandle) -> Task<Void,Never> { Task.detached { [job] in
                while true { let bytes=process.read(handle); if bytes.isEmpty { break }
                    await MainActor.run { if job.generation == generation { job.output=String((job.output+String(decoding:bytes,as:UTF8.self)).suffix(262144)) } }
                }
                try? handle.close()
            } }
            let out=reader(output.fileHandleForReading), err=reader(errors.fileHandleForReading)
            job.completion=Task { [weak self, weak job] in
                await Task.detached { process.waitUntilExit() }.value
                // Close admission before waiting for UI/output callbacks. This does not claim detached survivors died.
                self?.grants.end(scope,reason:.finished)
                await out.value; await err.value
                guard let job, job.generation == generation else { return }
                job.process=nil; job.scope=nil; job.usedGrants=[]
                job.state = job.state == .stopping || process.terminationStatus == 0 ? .stopped : .failed
            }
        } catch { grants.end(scope,reason:.cancelled); job.scope=nil; job.state = .failed; throw error }
    }
    func stop(_ job: AgentManagedJob) async {
        guard managed[job.id] === job else { return }
        if let scope=job.scope { grants.end(scope,reason:.cancelled) }
        if job.process != nil { job.state = .stopping; job.process?.terminate() }
        await job.completion?.value
    }
    func cancelOwner(_ owner: String) { for job in managed.values where job.owner == owner { Task { await self.stop(job) } } }

}
