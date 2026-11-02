import Foundation
import Combine
import Darwin

/// A launch contract intersects purpose ceilings with the normal policy compiler.
/// Values come from Milk's selected runtime/source/target, never RPC environment dictionaries.
@MainActor struct SandboxPurposePlan {
    let purpose: AgentBackendPurpose
    let authority: SandboxLaunchAuthority
    let closure: SandboxExecutableClosure
    let root: URL
    let workspace: URL
    let environment: [String:String]
    let profile: String?
    func check() throws {
        try Task.checkCancellation(); try authority.check()
        guard closure.revalidated() else { throw AgentError.message("Executable/interpreter identity changed before launch. Re-select or verify the runtime.") }
    }
    func observe(_ stop: @escaping () -> Void) -> AnyCancellable? {
        guard let settings=authority.settings else { return nil }
        return settings.$configuration.sink { value in
            var current=value, expected=authority.configuration
            current.autonomousTimeoutSeconds=30; expected.autonomousTimeoutSeconds=30
            if current != expected { stop() }
        }
    }
    static func make(purpose: AgentBackendPurpose, executable: URL, authority: SandboxLaunchAuthority,
                     root: URL, sourceEnvironment: [String:String] = [:], explicitEnvironment: [String:String] = [:],
                     support: [URL] = [], codeRoot: URL? = nil, integration: URL? = nil,
                     runtimeDependencies: [SandboxProfileBuilder.Root] = [], packageSource: URL? = nil, target: AgentDataProfile? = nil, project: URL? = nil) throws -> Self {
        guard [.versionProbe,.compatibilityProbe,.installationTransaction,.packageCommand].contains(purpose) else { throw AgentError.message("Unclassified utility purpose. No unrestricted launch is available.") }
        try authority.check()
        let fm=FileManager.default, resolver=SandboxPathResolver()
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let privateRoot=try resolver.resolve(root).canonicalURL
        let work=privateRoot.appendingPathComponent("work"), state=privateRoot.appendingPathComponent("state")
        for path in [work,state] { try fm.createDirectory(at:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        let toolchain=try SandboxToolchainEnvironment(source:sourceEnvironment)
        let closure: SandboxExecutableClosure
        if authority.configuration.enabled { closure=try SandboxExecutableClosure.inspect(executable,support:support,codeRoot:codeRoot,toolchain:toolchain) }
        else {
            let path=try resolver.resolve(executable)
            guard path.exists, fm.isExecutableFile(atPath:path.canonicalURL.path) else { throw SandboxPathError.invalidPath }
            let search=SandboxEnvironment.path(support:support,ambient:sourceEnvironment["PATH"]).split(separator:":").map { URL(fileURLWithPath:String($0)) }
            closure = .init(executable:path.canonicalURL,roots:[.init(url:path.canonicalURL,subtree:false)],searchDirectories:search,snapshots:[path])
        }
        var env=PiEnvironment.probe(source:sourceEnvironment,explicit:explicitEnvironment,work:state,support:closure.searchDirectories,toolchain:toolchain)
        // Probe/package commands never search ambient PATH or read a normal HOME/profile.
        env["PATH"]=closure.searchDirectories.map(\.path).joined(separator:":")
        env["HOME"]=state.path; env["TMPDIR"]=state.path
        env["PI_CODING_AGENT_DIR"]=state.appendingPathComponent("agent").path
        var deps=SandboxProfileBuilder.probeReadRoots+closure.roots+runtimeDependencies
        if let integration {
            for name in ["MilkPiIntegration.ts","MilkSandboxBridge.ts"] { deps.append(.init(url:integration.deletingLastPathComponent().appendingPathComponent(name),subtree:false)) }
        }
        // DEVELOPER_DIR/PI_PACKAGE_DIR are configuration, never generic filesystem grants.
        // Interpreter inspection supplies actual toolchain roots; runtimeDependencies
        // and the selected module/code graph supply package resources.
        var inactive=authority.inactiveProfiles
        var active: SandboxProfileRoot?
        var read=[SandboxProfileBuilder.Root(url:privateRoot)], write=[SandboxProfileBuilder.Root(url:privateRoot)]
        var readOnly: [SandboxProfileBuilder.Root]=[]
        if purpose == .packageCommand {
            guard let packageSource, let target else { throw AgentError.message("Package execution requires an explicit local source and target profile.") }
            let input=try resolver.resolve(packageSource)
            if !(try resolver.resolve(target.directory)).exists { try fm.createDirectory(at:target.directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
            let output=try resolver.resolve(target.directory)
            guard input.exists, output.isDirectory, !input.contains(output) else { throw AgentError.message("Package source/target are unavailable or overlap ambiguously.") }
            let profileRoot=SandboxProfileRoot(id:"package-target",agentID:.pi,url:output.canonicalURL,ownership:target.ownership == .sharedExisting ? .existing : .managed)
            active=profileRoot
            inactive.removeAll { (try? resolver.resolve($0.url).canonicalURL) == output.canonicalURL }
            env["PI_CODING_AGENT_DIR"]=output.canonicalURL.path
            deps.append(.init(url:input.canonicalURL,subtree:input.isDirectory))
            read.append(.init(url:output.canonicalURL)); write.append(.init(url:output.canonicalURL))
            try SandboxInputBoundary.check(input:input,writable:[output,try resolver.resolve(privateRoot)])
            readOnly.append(.init(url:input.canonicalURL,subtree:input.isDirectory))
        } else if target != nil || packageSource != nil { throw AgentError.message("This purpose cannot receive persistent profile/source authority.") }
        read += deps
        var configuration=authority.configuration
        // A purpose ceiling does not turn unrelated persistent folder grants into launch dependencies.
        let actualProject=project ?? work
        let key=try resolver.resolve(actualProject).canonicalURL.path
        let access=configuration.projects[key] ?? .init()
        configuration.projects=[:]
        let context=SandboxPolicyContext(configuration:configuration,projectConfiguration:access,
            roots:.init(project:actualProject,activeProfile:active,inactiveProfiles:inactive,writableBuildRoots:[privateRoot]),interaction:.approval,subject:.agentRuntime)
        var profile=try SandboxProfileBuilder().make(context:context,dependencies:deps)
        if profile != nil {
            func predicates(_ roots: [SandboxProfileBuilder.Root]) throws -> String {
                let values=try roots.flatMap { item -> [String] in
                    let path=try resolver.resolve(item.url)
                    let literal=try "(\(item.subtree ? "subpath":"literal") \(SandboxProfileBuilder.quote(path.canonicalURL.path)))"
                    let aliases=try path.observations.filter { $0.identity.kind == S_IFLNK }.map { "(literal \(try SandboxProfileBuilder.quote($0.path)))" }
                    return [literal]+aliases
                }
                return "(require-any \(values.joined(separator:" ")))"
            }
            // Ancestor metadata is already limited by the normal compiler. Data stays inside this purpose.
            let reads="(require-any \(try predicates(read)) (literal \"/var\") (literal \"/etc\") (literal \"/tmp\") (literal \"/private/var/db/xcode_select_link\"))", writes=try predicates(write)
            profile! += "\n(deny file-read-data file-read-xattr (require-not \(reads)))\n(deny file-write* (require-not (require-any \(writes) (literal \"/dev/null\"))))\n"
            for path in readOnly { profile! += "(deny file-write* \(try predicates([path])))\n" }
        }
        profile=try SandboxProfileBuilder.protectingCode(profile,roots:closure.roots+runtimeDependencies)
        return .init(purpose:purpose,authority:authority,closure:closure,root:privateRoot,workspace:work,environment:env,profile:profile)
    }
}
