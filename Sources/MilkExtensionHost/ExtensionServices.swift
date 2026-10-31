import Foundation
import AppKit
import Security
import UserNotifications
import Darwin
import MilkPTY
import MilkExtensionKit

@MainActor final class ScopedStorage: ExtensionStorage {
    let lease: ExtensionLease
    let root: URL
    let canonicalRoot: URL
    init(lease: ExtensionLease, root: URL) { self.lease=lease; self.root=root; canonicalRoot=root.resolvingSymlinksInPath() }
    private func checkRoot() throws {
        try lease.check()
        guard root.resolvingSymlinksInPath() == canonicalRoot, (try root.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeExtensionError.invalid("Extension data root was replaced or symlinked.") }
    }
    func read(_ relativePath: String) throws -> Data? {
        try checkRoot(); let url=try NativePackageInspector.contained(relativePath,root:root)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 8*1024*1024 else { throw NativeExtensionError.invalid("Storage file exceeds 8 MB.") }
        return try Data(contentsOf:url)
    }
    func write(_ data: Data, to relativePath: String) throws {
        try checkRoot(); guard data.count <= 8*1024*1024 else { throw NativeExtensionError.invalid("Storage file exceeds 8 MB.") }
        let url=try NativePackageInspector.contained(relativePath,root:root)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:.atomic)
    }
    func remove(_ relativePath: String) throws { try checkRoot(); let url=try NativePackageInspector.contained(relativePath,root:root); if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) } }
}
@MainActor final class ScopedWorkspace: ExtensionWorkspace {
    let lease: ExtensionLease
    let authorize: @MainActor (String,URL?) async throws -> Void
    init(lease: ExtensionLease, authorize: @escaping @MainActor (String,URL?) async throws -> Void) { self.lease=lease; self.authorize=authorize }
    var url: URL? { get throws { try lease.check(); return lease.workspace } }
    private func file(_ path: String) throws -> URL {
        guard let root=lease.workspace else { throw NativeExtensionError.invalid("No active workspace.") }
        return try NativePackageInspector.contained(path,root:root)
    }
    func read(_ relativePath: String) async throws -> Data {
        try lease.check(.workspaceRead); let url=try file(relativePath)
        let data=try await Task.detached { () throws -> Data in
            guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 8*1024*1024 else { throw NativeExtensionError.invalid("Workspace read exceeds 8 MB.") }
            return try Data(contentsOf:url)
        }.value
        try lease.check(.workspaceRead); return data
    }
    func write(_ data: Data, to relativePath: String) async throws {
        try lease.check(.workspaceWrite); let root=lease.workspace
        try await authorize("Write \(relativePath) (\(data.count) bytes)",root)
        try lease.check(.workspaceWrite)
        guard root == lease.workspace else { throw NativeExtensionError.invalid("Workspace changed during approval.") }
        let target=try file(relativePath); try data.write(to:target,options:.atomic)
        for observer in lease.observers { observer(root) }
    }
    func observe(_ handler: @escaping @MainActor (URL?) -> Void) throws { try lease.check(); lease.observers.append(handler); handler(lease.workspace) }
}
@MainActor final class ScopedNetwork: ExtensionNetwork {
    let lease: ExtensionLease
    let session: URLSession
    init(lease: ExtensionLease) {
        self.lease=lease
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=15; config.timeoutIntervalForResource=30
        config.httpCookieStorage=nil; config.urlCredentialStorage=nil
        session=URLSession(configuration:config)
    }
    func data(for request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        try lease.check(.network)
        guard let scheme=request.url?.scheme?.lowercased(), ["http","https"].contains(scheme), request.url?.user == nil, request.url?.password == nil else { throw NativeExtensionError.invalid("Network requests must use HTTP(S) without URL credentials.") }
        let (data,response)=try await session.data(for:request)
        try lease.check(.network)
        guard let response=response as? HTTPURLResponse else { throw NativeExtensionError.invalid("Expected an HTTP response.") }
        guard data.count <= 16*1024*1024 else { throw NativeExtensionError.invalid("Network response exceeds 16 MB.") }
        return (data,response)
    }
    func cancel() { session.invalidateAndCancel() }
}
@MainActor final class ScopedSecrets: ExtensionSecrets {
    let lease: ExtensionLease
    let dataRoot: URL
    init(lease: ExtensionLease, dataRoot: URL) { self.lease=lease; self.dataRoot=dataRoot }
    static func service(_ id: String) -> String { "dev.milk.extension."+id }
    func query(_ key: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service(lease.id),kSecAttrAccount as String:key] }
    func read(_ key: String) throws -> String? {
        try lease.check(.keychain); var q=query(key); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?; let code=SecItemCopyMatching(q as CFDictionary,&result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data=result as? Data else { throw NativeExtensionError.invalid("Extension Keychain read failed (\(code)).") }
        return String(data:data,encoding:.utf8)
    }
    func write(_ value: String?, for key: String) throws {
        try lease.check(.keychain); let q=query(key)
        if let value {
            let attributes=[kSecValueData as String:Data(value.utf8)]
            var code=SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
            if code == errSecItemNotFound { var entry=q; entry.merge(attributes) { _,new in new }; code=SecItemAdd(entry as CFDictionary,nil) }
            guard code == errSecSuccess else { throw NativeExtensionError.invalid("Extension Keychain write failed (\(code)).") }
            try Data().write(to:dataRoot.appendingPathComponent(".milk-keychain-used"),options:.atomic)
        } else { let code=SecItemDelete(q as CFDictionary); guard code == errSecSuccess || code == errSecItemNotFound else { throw NativeExtensionError.invalid("Extension Keychain deletion failed (\(code)).") } }
    }
    static func removeAll(_ id: String) throws {
        let q=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service(id),kSecMatchLimit as String:kSecMatchLimitAll] as [String:Any]
        let code=SecItemDelete(q as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw NativeExtensionError.invalid("Could not remove extension Keychain data (\(code)).") }
    }
}
@MainActor final class ScopedClipboard: ExtensionClipboard {
    let lease: ExtensionLease
    init(lease: ExtensionLease) { self.lease=lease }
    func read() throws -> String? { try lease.check(.clipboardRead); return NSPasteboard.general.string(forType:.string) }
    func write(_ text: String) throws { try lease.check(.clipboardWrite); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
}
@MainActor final class ScopedNotifications: ExtensionNotifications {
    let lease: ExtensionLease
    init(lease: ExtensionLease) { self.lease=lease }
    func post(title: String, body: String) async throws {
        try lease.check(.notifications)
        guard try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) else { throw NativeExtensionError.invalid("Notifications were declined.") }
        try lease.check(.notifications)
        let content=UNMutableNotificationContent(); content.title=title; content.body=body
        try await UNUserNotificationCenter.current().add(.init(identifier:lease.id+"."+UUID().uuidString,content:content,trigger:nil))
    }
}
@MainActor final class ScopedProcesses: ExtensionProcesses {
    let lease: ExtensionLease
    let host: ExtensionProcessHost
    let authorize: @MainActor (String,URL?) async throws -> Void
    init(lease: ExtensionLease, host: ExtensionProcessHost, authorize: @escaping @MainActor (String,URL?) async throws -> Void) { self.lease=lease; self.host=host; self.authorize=authorize }
    func launch(executable: URL, arguments: [String], workspaceScoped: Bool) async throws -> ExtensionProcess {
        try lease.check(.shell); let root=lease.workspace
        try await authorize("Run \(executable.path)\nArguments: \(arguments)",root)
        try lease.check(.shell)
        guard root == lease.workspace, !workspaceScoped || root != nil else { throw NativeExtensionError.invalid("Workspace is unavailable or changed during approval.") }
        return try host.launch(owner:lease.id,executable:executable,arguments:arguments,workspace:workspaceScoped ? root:nil)
    }
    func stop(_ process: ExtensionProcess) async { await host.stop(process,owner:lease.id) }
}
@MainActor final class ScopedGit: ExtensionGit {
    let lease: ExtensionLease
    let host: ExtensionProcessHost
    let authorize: @MainActor (String,URL?) async throws -> Void
    init(lease: ExtensionLease, host: ExtensionProcessHost, authorize: @escaping @MainActor (String,URL?) async throws -> Void) { self.lease=lease; self.host=host; self.authorize=authorize }
    func run(arguments: [String], writing: Bool) async throws -> String {
        try lease.check(writing ? .gitWrite:.gitRead)
        guard let root=lease.workspace else { throw NativeExtensionError.invalid("No workspace for Git.") }
        if writing { try await authorize("git \(arguments)",root); try lease.check(.gitWrite) }
        else { guard [["status","--porcelain=v1","--branch"],["diff","--no-ext-diff","--no-textconv"],["log","-20","--oneline"]].contains(arguments) else { throw NativeExtensionError.invalid("Read-only Git supports status --porcelain=v1 --branch, diff --no-ext-diff --no-textconv, or log -20 --oneline.") } }
        guard root == lease.workspace else { throw NativeExtensionError.invalid("Workspace changed during approval.") }
        let output=try await host.run(owner:lease.id,executable:URL(fileURLWithPath:"/usr/bin/git"),arguments:["--no-pager"]+arguments,workspace:root)
        try lease.check(); return output
    }
}

/// An owned child stays unreaped until group cleanup ends, preventing PID/group reuse during signals.
final class OwnedExtensionProcess: @unchecked Sendable {
    let token: ExtensionProcess
    let owner: String
    let workspace: URL?
    private let lock=NSLock()
    private let cleaned=DispatchGroup()
    private var stopping=false
    private var finished=false
    private var cleanupTimedOut=false
    private var callbacks: [() -> Void] = []
    var cleanupSucceeded=false
    var exitStatus: Int32?
    var onCleanupTimeout: (() -> Void)?
    var onExit: (() -> Void)?
    init(pid: pid_t, owner: String, workspace: URL?) { token = .init(id:UUID(),pid:pid); self.owner=owner; self.workspace=workspace; cleaned.enter() }
    func watch() {
        let thread=Thread { [self] in
            if milk_terminal_wait_exit(token.pid) == 0 {
                beginStop(); cleaned.wait(); var status: Int32=0; _ = milk_terminal_reap(token.pid,&status); exitStatus=status
            }
            lock.lock(); finished=true; let done=callbacks; callbacks=[]; lock.unlock()
            DispatchQueue.main.async { self.onExit?(); done.forEach { $0() } }
        }; thread.name="Milk Extension process reaper"; thread.start()
    }
    func wait(_ completion: @escaping () -> Void) {
        lock.lock(); if finished { lock.unlock(); completion(); return }; callbacks.append(completion); lock.unlock()
    }
    func stop(_ completion: @escaping () -> Void) {
        lock.lock(); if finished || cleanupTimedOut { lock.unlock(); completion(); return }; callbacks.append(completion); lock.unlock(); beginStop()
        // Do not make disable/quit wait indefinitely for a child stuck in a kernel wait.
        // Keep that child tracked and unreaped; never reuse its identity for another process.
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [self] in
            lock.lock()
            guard !finished, !cleanupTimedOut else { lock.unlock(); return }
            cleanupTimedOut=true; cleanupSucceeded=false
            let pending=callbacks; callbacks=[]; lock.unlock()
            onCleanupTimeout?(); pending.forEach { $0() }
        }
    }
    private func beginStop() {
        lock.lock(); if stopping { lock.unlock(); return }; stopping=true; lock.unlock()
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let group=token.pid
            _ = milk_process_group_signal(group,SIGTERM)
            // A zombie leader reserves the group identity through the entire bounded cleanup.
            for _ in 0..<25 { if milk_process_group_signal(group,0) == 0 { break }; usleep(20_000) }
            _ = milk_process_group_signal(group,SIGKILL)
            for _ in 0..<25 { if milk_process_group_signal(group,0) == 0 { break }; usleep(20_000) }
            cleanupSucceeded=milk_process_group_signal(group,0) == 0
            cleaned.leave()
        }
    }
}
@MainActor public final class ExtensionProcessHost {
    private var owned: [UUID:OwnedExtensionProcess] = [:]
    public private(set) var cleanupProblems: [String] = []
    public var count: Int { owned.count }
    public init() {}
    func launch(owner: String, executable: URL, arguments: [String], workspace: URL?, output: Pipe? = nil) throws -> ExtensionProcess {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath:executable.path), owned.values.filter({ $0.owner == owner }).count < 16 else { throw NativeExtensionError.invalid("Executable is unavailable or extension process limit reached.") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir(&actions,(workspace ?? FileManager.default.homeDirectoryForCurrentUser).path)
        posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0)
        for fd in 1...2 {
            if let output { posix_spawn_file_actions_adddup2(&actions,output.fileHandleForWriting.fileDescriptor,Int32(fd)) }
            else { posix_spawn_file_actions_addopen(&actions,Int32(fd),"/dev/null",O_WRONLY,0) }
        }
        posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)); posix_spawnattr_setpgroup(&attributes,0)
        let argv=([executable.path]+arguments).map { strdup($0) }+[nil]
        let environment: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME="+FileManager.default.homeDirectoryForCurrentUser.path, "MILK_EXTENSION_ID="+owner,"GIT_TERMINAL_PROMPT=0","GIT_OPTIONAL_LOCKS=0"]
        let env: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) }+[nil]
        defer { (argv+env).forEach { free($0) } }
        var pid: pid_t=0
        let error=argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&pid,executable.path,&actions,&attributes,UnsafeMutablePointer(mutating:a.baseAddress!),UnsafeMutablePointer(mutating:e.baseAddress!)) } }
        try? output?.fileHandleForWriting.close()
        guard error == 0 else { throw NativeExtensionError.invalid("Extension process launch failed: \(String(cString:strerror(error)))") }
        let child=OwnedExtensionProcess(pid:pid,owner:owner,workspace:workspace); owned[child.token.id]=child
        let childID=child.token.id
        child.onCleanupTimeout={ [weak self] in self?.cleanupProblems.append("Cleanup deadline exceeded for owned extension group \(pid), owner \(owner). The process remains tracked.") }
        child.onExit={ [weak self, weak child] in if child?.cleanupSucceeded == false { self?.cleanupProblems.append("Could not confirm cleanup of extension process group \(pid) owned by \(owner).") }; self?.owned[childID]=nil }; child.watch(); return child.token
    }
    func run(owner: String, executable: URL, arguments: [String], workspace: URL) async throws -> String {
        let output=Pipe()
        let token=try launch(owner:owner,executable:executable,arguments:arguments,workspace:workspace,output:output)
        guard let child=owned[token.id] else { throw NativeExtensionError.invalid("Owned Git process disappeared.") }
        let reading=Task.detached { () -> Data in
            var result=Data()
            while let data=try? output.fileHandleForReading.read(upToCount:65536), !data.isEmpty {
                if result.count < 1024*1024 { result.append(data.prefix(1024*1024-result.count)) }
            }
            try? output.fileHandleForReading.close(); return result
        }
        let deadline=Task { try? await Task.sleep(nanoseconds:30_000_000_000); if !Task.isCancelled { await self.stop(token,owner:owner) } }
        defer { deadline.cancel() }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { c in child.wait { c.resume() } }
        },onCancel:{ Task { @MainActor in await self.stop(token,owner:owner) } })
        guard child.cleanupSucceeded else { try? output.fileHandleForReading.close(); throw NativeExtensionError.invalid("Owned Git process cleanup exceeded its deadline.") }
        let data=await reading.value
        try Task.checkCancellation()
        guard child.exitStatus == 0 else { throw NativeExtensionError.invalid("Git failed or timed out: "+String(decoding:data,as:UTF8.self)) }
        return String(decoding:data,as:UTF8.self)
    }
    func stop(_ token: ExtensionProcess, owner: String) async {
        guard let child=owned[token.id], child.owner == owner, child.token == token else { return }
        await withCheckedContinuation { c in child.stop { c.resume() } }
    }
    public func stopAll(owner: String? = nil, workspaceOnly: Bool = false, matchingWorkspace: URL? = nil) async {
        let children=owned.values.filter { (owner == nil || $0.owner == owner) && (!workspaceOnly || $0.workspace != nil) && (matchingWorkspace == nil || $0.workspace == matchingWorkspace) }
        for child in children { child.stop {} }
        for child in children { await withCheckedContinuation { c in child.stop { c.resume() } } }
    }
}
