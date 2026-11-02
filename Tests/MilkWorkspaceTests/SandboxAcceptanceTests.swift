import XCTest
import Foundation
@testable import Milk

final class SandboxAcceptanceTests: XCTestCase {
    private func run(_ script: String, arguments: [String] = [], context: SandboxPolicyContext, cache: URL) async throws -> Int32 {
        let profile=try SandboxProfileBuilder().make(context:context,dependencies:SandboxProfileBuilder.systemReadRoots)
        let command=SandboxProfileBuilder.command(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c",script,"sh"]+arguments,profile:profile)
        let input=Pipe(), output=Pipe(), errors=Pipe()
        let process=try SandboxProcess(executable:command.0,arguments:command.1,directory:context.roots.project,environment:SandboxEnvironment.execution(home:cache,temporary:cache,support:[]),input:input,output:output,errors:errors)
        try input.fileHandleForWriting.close()
        async let stdout=Task.detached { while !process.read(output.fileHandleForReading).isEmpty {} }.value
        async let stderr=Task.detached { while !process.read(errors.fileHandleForReading).isEmpty {} }.value
        await stdout; await stderr
        await Task.detached { process.waitUntilExit() }.value
        return process.terminationStatus
    }
    func testKernelDeniesRetargetedAliasesTraversalAndStrongerOverlappingRoots() async throws {
        let fm=FileManager.default, base=fm.temporaryDirectory.appendingPathComponent("Milk-FinalPaths-"+UUID().uuidString).resolvingSymlinksInPath()
        let project=base.appendingPathComponent("project"), outside=base.appendingPathComponent("outside"), cache=base.appendingPathComponent("cache")
        for url in [project,outside,cache,project.appendingPathComponent("safe"),outside.appendingPathComponent("inactive")] { try fm.createDirectory(at:url,withIntermediateDirectories:true) }
        defer { try? fm.removeItem(at:base) }
        let protected=outside.appendingPathComponent("secret"), inactive=outside.appendingPathComponent("inactive/data")
        try Data("synthetic".utf8).write(to:protected); try Data("inactive".utf8).write(to:inactive)
        var config=SandboxConfiguration(home:base); config.protectedLocations=[]
        var context=SandboxPolicyContext(configuration:config,projectConfiguration:.init(),roots:.init(project:project,writableBuildRoots:[cache]),interaction:.approval)
        let alias=project.appendingPathComponent("alias")
        try fm.createSymbolicLink(at:alias,withDestinationURL:project.appendingPathComponent("safe"))
        let snapshot=try SandboxPathResolver().resolve(alias.appendingPathComponent("new"))
        // Compile before the host changes the alias: the kernel must still mediate its new real target.
        let oldProfile=try SandboxProfileBuilder().make(context:context,dependencies:SandboxProfileBuilder.systemReadRoots)
        try fm.removeItem(at:alias); try fm.createSymbolicLink(at:alias,withDestinationURL:outside)
        XCTAssertFalse(snapshot.revalidated())
        let command=SandboxProfileBuilder.command(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","printf bad > alias/new"],profile:oldProfile)
        let process=try SandboxProcess(executable:command.0,arguments:command.1,directory:project,environment:SandboxEnvironment.execution(home:cache,temporary:cache,support:[]),input:Pipe(),output:Pipe(),errors:Pipe())
        await Task.detached { process.waitUntilExit() }.value
        XCTAssertNotEqual(process.terminationStatus,0); XCTAssertFalse(fm.fileExists(atPath:outside.appendingPathComponent("new").path))
        let traversal=try await run("printf bad > ../outside/missing",context:context,cache:cache)
        XCTAssertNotEqual(traversal,0)
        let creation=try await run("mkdir new-directory && printf allowed > new-directory/new-file",context:context,cache:cache)
        XCTAssertEqual(creation,0)
        let hardLink=project.appendingPathComponent("hard-link")
        context.configuration.protectedLocations=[.init(url:protected)]
        context.configuration.globalAllowedFolders=[.init(url:base,access:.readWrite)]
        context.roots.inactiveProfiles=[.init(id:"inactive",agentID:.pi,url:outside.appendingPathComponent("inactive"),ownership:.existing)]
        let newLink=try await run("ln \"$1\" \"$2\"",arguments:[protected.path,hardLink.path],context:context,cache:cache)
        XCTAssertNotEqual(newLink,0,"Child created a new alias of the Protected file")
        XCTAssertFalse(fm.fileExists(atPath:hardLink.path))
        try fm.linkItem(at:protected,to:hardLink)
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context:context,dependencies:SandboxProfileBuilder.systemReadRoots),"Pre-existing aliases cannot be safely represented by pathname-only exclusions")
        try fm.removeItem(at:hardLink)
        context.projectConfiguration.access = .readOnly
        for path in [protected,inactive] {
            let read=try await run("cat \"$1\"",arguments:[path.path],context:context,cache:cache)
            XCTAssertNotEqual(read,0,"Stronger root lost through an allowed-folder or hard-link alias: \(path.lastPathComponent)")
            let write=try await run("printf bad > \"$1\"",arguments:[path.path],context:context,cache:cache)
            XCTAssertNotEqual(write,0)
        }
        let ro=try await run("printf bad > new-directory/new-file",context:context,cache:cache)
        XCTAssertNotEqual(ro,0)
        XCTAssertEqual(try Data(contentsOf:protected),Data("synthetic".utf8))
        context.roots.activeProfile = .init(id:"active",agentID:.pi,url:outside,ownership:.managed)
        XCTAssertThrowsError(try SandboxProfileBuilder().make(context:context,dependencies:SandboxProfileBuilder.systemReadRoots))
    }
}

extension SandboxHostEffectsTests {
    @MainActor func testFinalGitBranchRenameLogAndMetadataDeletionStayScoped() async throws {
        let base=try temporary(), root=try repository(base), (effects,grants)=try effects(base,root:root)
        for argv in [["log","--oneline"],["branch","acceptance"],["branch","-m","acceptance","renamed"],["branch","-D","renamed"],["diff","--cached"],["status","--short"]] {
            let result=try await callGit(argv,effects); XCTAssertEqual(result.code,0,result.text)
        }
        let linked=base.appendingPathComponent("linked")
        try git(["worktree","add","-b","linked-final",linked.path],root)
        let (linkedEffects,linkedGrants)=try self.effects(base,root:linked)
        for (host,store,directory) in [(effects,grants,root),(linkedEffects,linkedGrants,linked)] {
            let scope=try store.beginOperation(in:host.activation)
            let profile=try host.profile(scope)
            for command in ["rm -rf .git","printf bad > .git","git status --short; printf bad > .git/after-git"] {
                let result=try await host.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c",command],directory:directory,environment:SandboxEnvironment.execution(home:host.cache,temporary:host.cache,support:[]),profile:profile,scope:scope)
                XCTAssertNotEqual(result.code,0,"Direct shell command gained Git metadata authority")
                XCTAssertTrue(fm.fileExists(atPath:directory.appendingPathComponent(".git").path))
            }
            store.end(scope,reason:.finished)
        }
        XCTAssertEqual(try git(["rev-parse","--abbrev-ref","HEAD"],root).trimmingCharacters(in:.whitespacesAndNewlines),"main")
    }
}
