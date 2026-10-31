import AppKit
import Combine
import Darwin

struct PiExtensionRecord: Identifiable, Equatable {
    var id:String { settings.path+":"+path }
    var name:String
    var version:String?
    var path:String
    var source:String
    var scope:String
    var settings:URL
    var enabled:Bool
    var required=false
    var packageIndex:Int?
    var packageRoot:URL?
    var problem:String?
    var removable=false
    var toggleUnavailable:String?
    var kind:String { required ? "Milk integration · required":"Pi extension" }
}

/// Reads Pi's documented resource declarations without loading/executing extension code.
/// Writes preserve unrelated settings and cooperate with Pi's proper-lockfile directory lock.
@MainActor final class ExtensionService: ObservableObject {
    @Published private(set) var records:[PiExtensionRecord]=[]
    @Published private(set) var problems:[String]=[]
    @Published private(set) var pendingReload=false
    @Published private(set) var busy=false
    @Published private(set) var notice:String?
    private var runtimeProblems:[String]=[]
    private let existingAgentDirectory:URL
    var agentDirectory: URL {
        guard let installations else { return existingAgentDirectory }
        return (try? installations.selectedProfile().directory) ?? installations.store.root.appendingPathComponent("profile-unavailable")
    }
    var runtimeSelection: @MainActor () -> PiRuntimeMode = { .bundled }
    var lifecycle: AgentLifecycleCoordinator?
    var installations: PiInstallationManager?
    let runtime:PiRuntimeService
    private var workspace:URL?
    init(agentDirectory:URL? = nil,runtime:PiRuntimeService = PiRuntimeService()) {
        self.existingAgentDirectory=agentDirectory ?? ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath:($0 as NSString).expandingTildeInPath) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        self.runtime=runtime
    }
    func reportRuntimeProblem(_ text:String) {
        if !runtimeProblems.contains(text) { runtimeProblems.append(text); runtimeProblems=Array(runtimeProblems.suffix(30)) }
        refresh(workspace:workspace)
    }
    func refresh(workspace:URL?) {
        self.workspace=workspace
        var found:[PiExtensionRecord]=[], issues=runtimeProblems
        let internalPath=runtime.resources.appendingPathComponent("MilkPiIntegration.ts")
        found.append(.init(name:"Milk Pi integration",version:nil,path:internalPath.path,source:"Milk.app",scope:"Internal",settings:agentDirectory.appendingPathComponent("settings.json"),enabled:true,required:true,problem:FileManager.default.fileExists(atPath:internalPath.path) ? nil:"Required integration is missing; reinstall Milk."))
        var scopes=[("Personal",agentDirectory)]
        if let workspace { scopes.append(("Project",workspace.appendingPathComponent(".pi"))) }
        for (scope,base) in scopes {
            let settings=base.appendingPathComponent("settings.json")
            do {
                let config=try read(settings)
                let patterns=config["extensions"] as? [String] ?? []
                if config["extensions"] != nil && config["extensions"] as? [String] == nil { issues.append("\(settings.path): extensions must be an array of paths.") }
                var paths=entries(base.appendingPathComponent("extensions"))
                for item in patterns where !item.hasPrefix("-") && !item.hasPrefix("!") && !item.contains("*") && !item.hasPrefix("builtin:") && !item.hasPrefix("+builtin:") {
                    let url=resolve(item.hasPrefix("+") ? String(item.dropFirst()):item,base:base)
                    if !FileManager.default.fileExists(atPath:url.path) {
                        found.append(.init(name:url.lastPathComponent,path:url.path,source:"Configured path",scope:scope,settings:settings,enabled:true,problem:"Extension path is missing."))
                    } else { paths += entries(url) }
                }
                for url in Array(Set(paths)).sorted(by:{$0.path<$1.path}) {
                    found.append(.init(name:url.deletingPathExtension().lastPathComponent,path:url.path,source:"Auto-discovered / configured",scope:scope,settings:settings,enabled:enabled(url.path,patterns:patterns.filter { $0.hasPrefix("!") || $0.hasPrefix("+") || $0.hasPrefix("-") },base:base,defaultValue:true)))
                }
                if scope == "Personal" {
                    for name in ["mcp","llama.cpp","codemode","tool-search"] {
                        let path="builtin:"+name
                        found.append(.init(name:name,path:path,source:"Pi built-in",scope:scope,settings:settings,enabled:enabled(path,patterns:patterns.filter { $0.hasPrefix("!") || $0.hasPrefix("+") || $0.hasPrefix("-") },base:base,defaultValue:true)))
                    }
                }
                let packages=config["packages"] as? [Any] ?? []
                for (index,package) in packages.enumerated() {
                    let object=package as? [String:Any]
                    guard let source=package as? String ?? object?["source"] as? String else { issues.append("\(settings.path): invalid package declaration."); continue }
                    let root=packagePath(source,base:base)
                    guard let root else { issues.append("Cannot resolve package source \(source) without Pi metadata."); continue }
                    let manifestURL=root.appendingPathComponent("package.json")
                    var manifest:[String:Any]=[:]
                    do { manifest=try read(manifestURL) } catch { issues.append("\(manifestURL.path): invalid package manifest.") }
                    if let pi=manifest["pi"] {
                        if let object=pi as? [String:Any] {
                            if object["extensions"] != nil && object["extensions"] as? [String] == nil { issues.append("\(manifestURL.path): pi.extensions must be an array of paths.") }
                        } else { issues.append("\(manifestURL.path): pi manifest must be an object.") }
                    }
                    let resources=packageEntries(root,manifest:manifest)
                    let filterable=(manifest["pi"] as? [String:Any]) != nil || FileManager.default.fileExists(atPath:root.appendingPathComponent("extensions").path)
                    let resourceBase=(try? root.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true ? root.deletingLastPathComponent():root
                    let filters=object?["extensions"] as? [String]
                    if !FileManager.default.fileExists(atPath:root.path) {
                        found.append(.init(name:source,path:root.path,source:source,scope:scope,settings:settings,enabled:false,packageIndex:index,packageRoot:root,problem:"Configured package path is missing.",removable:scope == "Personal" && isLocal(source),toggleUnavailable:filterable ? nil:"Pi 1.4.0 does not apply enable/disable filters to this direct package source. Remove its local registration to stop loading it, or use a Pi package with a declared extensions manifest."))
                    }
                    for url in resources {
                        found.append(.init(name:(manifest["name"] as? String).map { $0+" / "+url.lastPathComponent } ?? url.lastPathComponent,version:manifest["version"] as? String,path:url.path,source:source,scope:scope,settings:settings,enabled:filterable ? (filters.map { enabled(url.path,patterns:$0,base:resourceBase,defaultValue:!$0.isEmpty) } ?? true):true,packageIndex:index,packageRoot:resourceBase,problem:FileManager.default.fileExists(atPath:url.path) ? nil:"Manifest extension path is missing.",removable:scope == "Personal" && isLocal(source),toggleUnavailable:filterable ? nil:"Pi 1.4.0 does not apply enable/disable filters to this direct package source. Remove its local registration to stop loading it, or use a Pi package with a declared extensions manifest."))
                    }
                }
            } catch { issues.append("\(settings.path): \(error.localizedDescription)") }
        }
        // Project policy may override a personal built-in selection. Report desired configuration,
        // never claim project declarations are trusted or that a running runtime has reloaded them.
        if let project=workspace?.appendingPathComponent(".pi"), let cfg=try? read(project.appendingPathComponent("settings.json")),let patterns=cfg["extensions"] as? [String] {
            for i in found.indices where found[i].path.hasPrefix("builtin:") { found[i].enabled=enabled(found[i].path,patterns:patterns.filter { $0.hasPrefix("!") || $0.hasPrefix("+") || $0.hasPrefix("-") },base:project,defaultValue:found[i].enabled) }
        }
        for i in found.indices where URL(fileURLWithPath:found[i].path).resolvingSymlinksInPath() == internalPath.resolvingSymlinksInPath() {
            found[i].required=true; found[i].enabled=true; found[i].removable=false
        }
        records=found
        problems=issues+found.compactMap { record in record.problem.map { record.name+": "+$0 } }
    }
    private func read(_ url:URL) throws -> [String:Any] {
        guard FileManager.default.fileExists(atPath:url.path) else { return [:] }
        let data=try Data(contentsOf:url)
        guard data.count<4_000_000,let object=try JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed]) as? [String:Any] else { throw AgentError.message("Invalid Pi configuration JSON.") }
        return object
    }
    private func resolve(_ path:String,base:URL) -> URL {
        let expanded=(path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath:expanded).standardizedFileURL:base.appendingPathComponent(expanded).standardizedFileURL
    }
    private func entries(_ url:URL) -> [URL] {
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory) else { return [] }
        if !isDirectory.boolValue { return ["ts","js"].contains(url.pathExtension) ? [url]:[] }
        for name in ["index.ts","index.js"] { let entry=url.appendingPathComponent(name); if FileManager.default.fileExists(atPath:entry.path) { return [entry] } }
        let children=(try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey],options:.skipsHiddenFiles)) ?? []
        return children.filter { ["ts","js"].contains($0.pathExtension) } + children.filter { (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "node_modules" }.flatMap { folder in
            ["index.ts","index.js"].map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath:$0.path) }.prefix(1)
        }
    }
    private func packageEntries(_ root:URL,manifest:[String:Any]) -> [URL] {
        if let paths=(manifest["pi"] as? [String:Any])?["extensions"] as? [String] {
            var values:[URL]=[]
            for path in paths where !path.hasPrefix("!") {
                if path.contains("*") || path.contains("?") {
                    if let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:.skipsHiddenFiles) {
                        var count=0
                        while let file=enumerator.nextObject() as? URL, count<10000 {
                            count += 1
                            if ["node_modules",".git"].contains(file.lastPathComponent) { enumerator.skipDescendants(); continue }
                            let relative=String(file.path.dropFirst(root.path.count+1))
                            if fnmatch(path.replacingOccurrences(of:"./",with:""),relative,0)==0 { values += entries(file) }
                        }
                    }
                } else { let url=resolve(path,base:root); values += FileManager.default.fileExists(atPath:url.path) ? entries(url):[url] }
            }
            return Array(Set(values)).filter { enabled($0.path,patterns:paths.filter { $0.hasPrefix("!") },base:root,defaultValue:true) }.sorted { $0.path<$1.path }
        }
        let conventional=entries(root.appendingPathComponent("extensions"))
        return conventional.isEmpty ? entries(root):conventional
    }
    private func isLocal(_ source:String) -> Bool {
        !["npm:","git:","https:","http:","ssh:","git@"].contains(where:source.hasPrefix)
    }
    private func packagePath(_ source:String,base:URL) -> URL? {
        if isLocal(source) { return resolve(source,base:base) }
        if source.hasPrefix("npm:") {
            let spec=String(source.dropFirst(4)); let name=spec.hasPrefix("@") ? "@"+spec.dropFirst().split(separator:"@")[0] : String(spec.split(separator:"@")[0])
            return base.appendingPathComponent("npm/node_modules/"+name)
        }
        var value=source.hasPrefix("git:") ? String(source.dropFirst(4)):source
        if value.hasPrefix("git@"),let colon=value.firstIndex(of:":") { value="https://"+value[value.index(value.startIndex,offsetBy:4)..<colon]+"/"+value[value.index(after:colon)...] }
        let qualified=value.contains("://") ? value:"https://"+value
        guard let url=URL(string:qualified),let host=url.host else { return nil }
        let path=url.path.replacingOccurrences(of:#"(?:\.git)?@[^/]+$|\.git$"#,with:"",options:.regularExpression)
        return base.appendingPathComponent("git/"+host+path)
    }
    private func enabled(_ path:String,patterns:[String],base:URL,defaultValue:Bool) -> Bool {
        func matches(_ entry:String,exact:Bool) -> Bool {
            let resolved=entry.hasPrefix("builtin:") ? entry:resolve(entry,base:base).path
            let actual=path.hasPrefix("builtin:") ? path:resolve(path,base:base).path
            return actual == resolved || (!exact && fnmatch(resolved,actual,0)==0)
        }
        let includes=patterns.filter { !$0.hasPrefix("!") && !$0.hasPrefix("+") && !$0.hasPrefix("-") }
        var result=includes.isEmpty ? defaultValue:includes.contains { matches($0,exact:false) }
        if patterns.contains(where:{$0.hasPrefix("!") && matches(String($0.dropFirst()),exact:false)}) { result=false }
        if patterns.contains(where:{$0.hasPrefix("+") && matches(String($0.dropFirst()),exact:true)}) { result=true }
        if patterns.contains(where:{$0.hasPrefix("-") && matches(String($0.dropFirst()),exact:true)}) { result=false }
        return result
    }

    private func mutate(_ settings:URL,_ edit:(inout [String:Any]) throws -> Void) throws {
        let fm=FileManager.default
        if (try? settings.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw AgentError.message("Refusing to replace a symlinked Pi settings file.") }
        try fm.createDirectory(at:settings.deletingLastPathComponent(),withIntermediateDirectories:true)
        let lock=URL(fileURLWithPath:settings.path+".lock")
        do { try fm.createDirectory(at:lock,withIntermediateDirectories:false) }
        catch { throw AgentError.message("Pi settings are locked by another writer. Try again after it finishes.") }
        defer { try? fm.removeItem(at:lock) }
        var json=try read(settings); try edit(&json)
        let data=try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        try data.write(to:settings,options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:settings.path)
    }
    func setEnabled(_ record:PiExtensionRecord,_ enabled:Bool) throws {
        guard !record.required,records.contains(record) else { throw AgentError.message("The required Milk integration cannot be changed. Refresh extension state.") }
        if let reason=record.toggleUnavailable { throw AgentError.message(reason) }
        try mutate(record.settings) { config in
            if let index=record.packageIndex, let root=record.packageRoot {
                var packages=config["packages"] as? [Any] ?? []
                guard packages.indices.contains(index) else { throw AgentError.message("Package settings changed. Refresh first.") }
                var package=packages[index] as? [String:Any] ?? ["source":packages[index]]
                guard package["source"] as? String == record.source else { throw AgentError.message("Package settings changed. Refresh first.") }
                let relative=String(record.path.dropFirst(root.path.count+1))
                var patterns=package["extensions"] as? [String] ?? ["**"]
                patterns.removeAll { $0 == "+"+relative || $0 == "-"+relative }
                patterns.append((enabled ? "+":"-")+relative)
                package["extensions"]=patterns; packages[index]=package; config["packages"]=packages
            } else {
                var patterns=config["extensions"] as? [String] ?? []
                let base=record.settings.deletingLastPathComponent()
                patterns.removeAll {
                    guard $0.hasPrefix("+") || $0.hasPrefix("-") else { return false }
                    let target=String($0.dropFirst())
                    return target == record.path || resolve(target,base:base).path == record.path
                }
                patterns.append((enabled ? "+":"-")+record.path); config["extensions"]=patterns
            }
        }
        pendingReload=true; notice="Saved for the next Pi runtime. Running sessions keep their loaded extensions."
        refresh(workspace:workspace)
    }
    func chooseInstall() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=true
        panel.message="Choose a trusted local Pi extension or package. Local sources stay in place; Pi does not install dependencies for them."
        if panel.runModal() == .OK,let url=panel.url { install(url) }
    }
    func install(_ url:URL) {
        guard !busy else { return }
        busy=true
        Task {
            defer { busy=false }
            do {
                guard url.isFileURL, !packageEntries(url,manifest:(try? read(url.appendingPathComponent("package.json"))) ?? [:]).isEmpty || ["ts","js"].contains(url.pathExtension) else { throw AgentError.message("Choose a local .ts/.js extension, index extension folder, or Pi package with extensions.") }
                let alert=NSAlert(); alert.messageText="Install trusted Pi extension?"; alert.informativeText="\(url.path)\n\nExtensions run with your user permissions and may access files and credentials. Source stays in place. Applies to new runtimes."
                alert.addButton(withTitle:"Install"); alert.addButton(withTitle:"Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await installLocalRegistration(url)
                pendingReload=true; notice="Extension installed in Pi's personal configuration. Reconnect idle Pi runtimes to load it."
                refresh(workspace:workspace)
            } catch { notice=error.localizedDescription }
        }
    }
    // The UI confirms trust before calling this canonical local-only installation path.
    func installLocalRegistration(_ url:URL) async throws {
        guard url.isFileURL, FileManager.default.fileExists(atPath:url.path),
              !packageEntries(url,manifest:(try? read(url.appendingPathComponent("package.json"))) ?? [:]).isEmpty else { throw AgentError.message("No supported local Pi extension entry was found.") }
        let integration=runtime.resources.appendingPathComponent("MilkPiIntegration.ts").resolvingSymlinksInPath()
        guard url.resolvingSymlinksInPath() != integration else { throw AgentError.message("Milk's internal integration is already required and managed by the app.") }
        try await packageCommand("install",source:url.path)
        pendingReload=true; refresh(workspace:workspace)
    }
    func uninstall(_ record:PiExtensionRecord) async throws {
        guard !record.required,record.removable,isLocal(record.source),record.scope == "Personal",records.contains(record) else { throw AgentError.message("Only known personal local package registrations can be removed here. Source files are preserved.") }
        guard !busy else { throw AgentError.message("An extension operation is in progress.") }
        busy=true; defer { busy=false }
        try await packageCommand("remove",source:resolve(record.source,base:agentDirectory).path)
        pendingReload=true; notice="Removed Pi package registration. Local source files are preserved."
        refresh(workspace:workspace)
    }
    private func packageCommand(_ command:String,source:String) async throws {
        let owner = lifecycle ?? AgentLifecycleCoordinator()
        let lease = owner.begin(activation: .init(agentID: .pi, workspace: agentDirectory, sessionID: -1), purpose: .packageCommand,
                                factory: { AgentOperationResource() }) { _, lease in
            try await self.runPackageCommand(command, source: source, owner: owner)
            try lease.check()
        }
        try await withTaskCancellationHandler(operation: {
            do { try await lease.work.value; try Task.checkCancellation(); try await owner.stopAndWait(lease) }
            catch { try await owner.stopAndWait(lease); throw error }
        }, onCancel: { Task { @MainActor in owner.stop(lease) } })
    }
    private func runPackageCommand(_ command: String, source: String, owner: AgentLifecycleCoordinator) async throws {
        let runtime=self.runtime, directory=agentDirectory
        let location: PiLaunchContext
        if let installations { location = try await installations.resolve(legacy: runtimeSelection(), owner: owner) }
        else { location = try await PiLaunchResolver(runtime: runtime).resolve(runtimeSelection(), lifecycle: owner) }
        try Task.checkCancellation()
        var env = location.environment
        env["PI_CODING_AGENT_DIR"] = directory.path; env["PI_OFFLINE"] = "1"
        let (data, status) = try await PiUtilityProcess.execute(executable: location.executable,
            arguments: [command, source, "--no-approve"], directory: FileManager.default.temporaryDirectory,
            environment: env, timeout: 20, mergeErrors: true, purpose: .packageCommand, lifecycle: owner)
        guard status == 0 else { throw AgentError.message("Pi package command failed: " + String(decoding: data.suffix(4000), as: UTF8.self)) }
    }

    func reconnect(_ agent:AgentService) throws {
        try agent.reconnectIdleRuntimes(); pendingReload=false; runtimeProblems=[]
        notice="Idle runtimes will reconnect. Saved session history is preserved."; refresh(workspace:workspace)
    }
}
