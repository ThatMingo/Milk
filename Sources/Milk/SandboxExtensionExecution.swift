import Foundation
import Darwin
import MilkExtensionHost
import MilkExtensionKit

extension SandboxHostEffects {
    static var extensionWorkerExecutable: URL {
        let packaged=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MilkExtensionWorker")
        if Bundle.main.bundleURL.pathExtension == "app" { return packaged }
        // SwiftPM development/testing uses the explicitly adjacent Milk-owned build product.
        let peer=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("MilkExtensionWorker")
        if FileManager.default.isExecutableFile(atPath:peer.path) { return peer }
        return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("MilkExtensionWorker")
    }
    func extensionTool(id: String, arguments: JSONValue, manager: NativeExtensionManager, scope: SandboxOperationScope,
                       helper: URL? = nil) async throws -> Output {
        let helperPath=try SandboxPathResolver().resolve(helper ?? Self.extensionWorkerExecutable)
        guard helperPath.exists, helperPath.finalIdentity?.kind == S_IFREG, helperPath.revalidated() else { throw AgentError.message("Milk extension worker is unavailable. Rebuild/reinstall Milk.") }
        let helper=helperPath.canonicalURL
        let invocation=try await manager.prepareAgentTool(id:id,arguments:Data(arguments.encodedString.utf8),workspace:activation.workspace)
        try check(scope)
        let subscription=manager.agentWorkersChanged.sink { [weak self, weak manager] in
            guard let self, let manager else { return }
            if !manager.agentToolIsLive(invocation) { self.cancel(scope); self.cancelOwner(invocation.tool.owner) }
        }
        defer { subscription.cancel() }
        let tool=invocation.tool.item, display=tool.id+" "+arguments.encodedString
        var prompted=false
        for file in tool.files {
            let target: URL
            switch file.source {
            case .argument:
                guard let raw=arguments[file.path].string, !raw.isEmpty else { throw AgentError.message("Missing worker path argument: "+file.path) }
                target=raw.hasPrefix("/") ? URL(fileURLWithPath:raw) : activation.workspace.appendingPathComponent(raw)
            case .storage:
                guard !file.path.isEmpty, !file.path.hasPrefix("/"), !file.path.split(separator:"/").contains("..") else { throw SandboxPathError.invalidPath }
                target=invocation.request.storageURL.appendingPathComponent(file.path)
            @unknown default: throw AgentError.message("Unsupported worker filesystem declaration.")
            }
            if try await authorize(target,action:file.writing ? .write : .read,scope:scope,tool:tool.id,command:display,subject:.extensionWorker) { prompted=true }
        }
        if !prompted { try await approvals.action(operation:scope,tool:tool.id,command:display,effect:"Run this extension agent tool in Milk's separate sandbox worker. Native UI services are unavailable.",mode:mode()) }
        try check(scope)
        guard manager.agentToolIsLive(invocation), FileManager.default.isExecutableFile(atPath:helper.path) else { throw AgentError.message("Extension worker is missing or contribution was revoked. Rebuild/reinstall Milk.") }
        let work=cache.appendingPathComponent("extension-"+scope.id.uuidString)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let framework=helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks")
        let extra=[SandboxProfileBuilder.Root(url:helper,subtree:false),.init(url:helper.deletingLastPathComponent().appendingPathComponent("libMilkExtensionKit.dylib"),subtree:false),.init(url:framework),.init(url:invocation.request.packageURL)]
        var sbpl=try profile(scope,subject:.extensionWorker,extra:extra)
        if sbpl != nil {
            // Narrow worker-only service boundary, independent of trusted native UI.
            sbpl! += "\n(deny appleevent-send)\n(deny mach-lookup (regex #\"^(com\\\\.apple\\\\.(securityd|secd|pbs|pasteboard)|com\\\\.apple\\\\.cfprefsd\\\\.agent))\"))\n"
            if !tool.requiredCapabilities.contains(.network) { sbpl! += "(deny network*)\n" }
            if !tool.requiredCapabilities.contains(.shell) { sbpl! += "(deny process-fork)\n(deny process-exec (require-not (literal \""+helper.path.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\")))\n" }
        }
        let env=SandboxEnvironment.execution(home:work,temporary:work,support:[])
        let command=SandboxProfileBuilder.command(executable:helper,arguments:[],profile:sbpl)
        let stdin=Pipe(), stdout=Pipe(), stderr=Pipe()
        let process=try SandboxProcess(executable:command.0,arguments:command.1,directory:activation.workspace,environment:env,input:stdin,output:stdout,errors:stderr)
        processes[scope.id,default:[]].append(process)
        let errors=Task.detached { var bytes=Data(); while true { let chunk=process.read(stderr.fileHandleForReading); if chunk.isEmpty { break }; if bytes.count < 65536 { bytes.append(chunk) } }; return bytes }
        let frames=AsyncThrowingStream<JSONValue,Error> { continuation in
            Task.detached {
                do {
                    var pending=Data()
                    while true {
                        let chunk=process.read(stdout.fileHandleForReading); if chunk.isEmpty { break }
                        pending.append(chunk); guard pending.count <= 8*1024*1024 else { throw AgentError.message("Extension worker frame limit exceeded.") }
                        while let newline=pending.firstIndex(of:10) {
                            let frame=pending[..<newline]; pending.removeSubrange(...newline)
                            continuation.yield(try JSONDecoder().decode(JSONValue.self,from:Data(frame)))
                        }
                    }
                    guard pending.isEmpty else { throw AgentError.message("Incomplete extension worker frame.") }
                    continuation.finish()
                } catch { process.terminate(); continuation.finish(throwing:error) }
            }
        }
        var completed=false
        let lifetime=Task { [weak self] in
            await Task.detached { process.waitUntilExit() }.value
            if !completed { self?.cancel(scope) }
        }
        let result: Output
        do {
            result=try await withTaskCancellationHandler(operation:{
                try stdin.fileHandleForWriting.write(contentsOf:JSONEncoder().encode(invocation.request)+Data([10]))
                for try await frame in frames {
                    try check(scope); guard manager.agentToolIsLive(invocation) else { throw CancellationError() }
                    switch frame["kind"].string {
                    case "git":
                        let arguments=frame["arguments"].array.compactMap(\.string)
                        guard arguments.count == frame["arguments"].array.count else { throw AgentError.message("Malformed worker Git request.") }
                        let command=try SandboxGitCommand.recognize(arguments)
                        guard tool.requiredCapabilities.contains(command.writes ? .gitWrite : .gitRead) else { throw AgentError.message("Worker tool did not declare this Git capability.") }
                        let reply: JSONValue
                        do { let output=try await git(arguments:arguments,scope:scope); reply = .object(["result":.string(output.text),"code":.number(Double(output.code))]) }
                        catch { reply = .object(["error":.string(error.localizedDescription)]) }
                        try check(scope); guard manager.agentToolIsLive(invocation) else { throw CancellationError() }
                        try stdin.fileHandleForWriting.write(contentsOf:Data((reply.encodedString+"\n").utf8))
                    case "result":
                        guard let text=frame["text"].string else { throw AgentError.message("Malformed worker result.") }
                        completed=true; return Output(text:text,code:0)
                    case "failure": throw AgentError.message(frame["error"].string ?? "Extension worker failed.")
                    default: throw AgentError.message("Unsupported worker host effect. No generic service bridge exists.")
                    }
                }
                throw AgentError.message("Extension worker exited without a result.")
            },onCancel:{ process.terminate() })
        } catch {
            completed=true; process.terminate(); await lifetime.value; _=await errors.value
            processes[scope.id]?.removeAll { $0 === process }; throw error
        }
        process.terminate(); await lifetime.value; _=await errors.value
        processes[scope.id]?.removeAll { $0 === process }
        try check(scope); return result
    }
}
