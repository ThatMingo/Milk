import XCTest
import Foundation
import Darwin
@testable import Milk

final class SandboxPurposeTests: XCTestCase {
    var project: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func fixture() throws -> URL {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Purpose-Test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:base) }
        return try SandboxPathResolver().resolve(base).canonicalURL
    }
    func script(_ base: URL, _ name: String, _ text: String) throws -> URL {
        let file=base.appendingPathComponent(name); try Data(text.utf8).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path); return file
    }
    @MainActor func authority(_ base: URL, enabled: Bool = true, configure: ((inout SandboxConfiguration) -> Void)? = nil) throws -> SandboxLaunchAuthority {
        var c=SandboxConfiguration(home:base); c.protectedLocations=[]; c.enabled=enabled; configure?(&c)
        let suite="Milk.Purpose."+UUID().uuidString, defaults=UserDefaults(suiteName:suite)!
        defaults.set(try JSONEncoder().encode(c),forKey:SandboxSettingsStore.key)
        let settings=SandboxSettingsStore(defaults:defaults,home:base)
        addTeardownBlock { defaults.removePersistentDomain(forName:suite) }
        return .init(configuration:c,isValid:true,inactiveProfiles:[],settings:settings)
    }
    @MainActor func execute(_ plan: SandboxPurposePlan, arguments: [String] = []) async throws -> (String,Int32) {
        let output=try await PiUtilityProcess.execute(executable:plan.closure.executable,arguments:arguments,timeout:10,mergeErrors:true,purpose:plan.purpose,lifecycle:nil,plan:plan)
        return (String(decoding:output.0,as:UTF8.self),output.1)
    }
    @MainActor func testProbePurposePrivateStorageNoKeysOutsideAndExplicitOff() async throws {
        let base=try fixture(), forbidden=base.appendingPathComponent("forbidden")
        let exe=try script(base,"probe","""
        #!/bin/sh
        test -z "${MILK_PI_LOCAL_KEY:-}${OPENAI_API_KEY:-}${BASH_ENV:-}${NODE_OPTIONS:-}${GIT_CONFIG_COUNT:-}" || exit 9
        printf private > "$HOME/state"
        printf scratch > scratch
        printf outside > '\(forbidden.path)' 2>/dev/null
        printf 'home=%s tmp=%s profile=%s' "$HOME" "$TMPDIR" "$PI_CODING_AGENT_DIR"
        """)
        for enabled in [true,false] {
            let a=try authority(base,enabled:enabled)
            let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent(UUID().uuidString),sourceEnvironment:["MILK_PI_LOCAL_KEY":"synthetic","OPENAI_API_KEY":"synthetic","BASH_ENV":"/bad","PATH":".:relative:/usr/bin"])
            let result=try await execute(plan); XCTAssertEqual(result.1,0,result.0)
            XCTAssertTrue(result.0.contains(plan.root.path),result.0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:plan.workspace.appendingPathComponent("scratch").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath:forbidden.path),!enabled)
            XCTAssertEqual(plan.profile == nil,!enabled)
            XCTAssertFalse(plan.environment["PATH"]!.split(separator:":").contains { !$0.hasPrefix("/") })
        }
    }
    func testExecutableClosureMachOInterpreterChainsAndMalformedFailClosed() throws {
        let base=try fixture()
        for binary in ["/bin/sh","/bin/zsh","/usr/bin/python3"] { XCTAssertFalse(try SandboxExecutableClosure.inspect(URL(fileURLWithPath:binary)).roots.isEmpty,binary) }
        for text in ["garbage","#!relative/sh\necho bad\n","#!/usr/bin/env -S node --bad\n","#!/missing/interpreter\n","#!/usr/bin/env missing-interpreter-milk\n"] {
            let exe=try script(base,UUID().uuidString,text)
            XCTAssertThrowsError(try SandboxExecutableClosure.inspect(exe))
        }
        let selected=try script(base,"env-shell","#!/usr/bin/env sh\nprintf safe\n")
        let chain=try SandboxExecutableClosure.inspect(selected)
        XCTAssertTrue(chain.snapshots.contains { $0.canonicalURL.path == "/usr/bin/env" })
        XCTAssertTrue(chain.revalidated())
        try FileManager.default.removeItem(at:selected); _=try script(base,"env-shell","#!/bin/sh\nprintf changed\n")
        XCTAssertFalse(chain.revalidated())
    }
    @MainActor func testPackageSourceIsReadOnlyTargetScopedAndProtectedRulesWin() async throws {
        let base=try fixture(), source=base.appendingPathComponent("source"), target=base.appendingPathComponent("profile")
        for url in [source,target] { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        let exe=try script(base,"package-cli","""
        #!/bin/sh
        printf saved > "$PI_CODING_AGENT_DIR/settings"
        printf forbidden > '\(source.appendingPathComponent("mutated").path)' 2>/dev/null
        printf complete
        """)
        let a=try authority(base)
        let plan=try SandboxPurposePlan.make(purpose:.packageCommand,executable:exe,authority:a,root:base.appendingPathComponent("private"),packageSource:source,target:.init(directory:target,ownership:.sharedExisting))
        let result=try await execute(plan); XCTAssertEqual(result.1,0,result.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:target.appendingPathComponent("settings").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.appendingPathComponent("mutated").path))
        let protected=try authority(base) { $0.protectedLocations=[.init(url:target)] }
        let denied=try SandboxPurposePlan.make(purpose:.packageCommand,executable:exe,authority:protected,root:base.appendingPathComponent("denied"),packageSource:source,target:.init(directory:target,ownership:.sharedExisting))
        try FileManager.default.removeItem(at:target.appendingPathComponent("settings"))
        _=try await execute(denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("settings").path))
    }
    @MainActor func testSystemPythonShimActuallyExecutesWithinDeclaredClosure() async throws {
        let base=try fixture(), a=try authority(base)
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:URL(fileURLWithPath:"/usr/bin/python3"),authority:a,root:base.appendingPathComponent("private"))
        let result=try await execute(plan,arguments:["--version"])
        XCTAssertEqual(result.1,0,result.0)
    }
    @MainActor func testPythonScriptVersionExecutesWithinDeclaredClosure() async throws {
        let base=try fixture(), a=try authority(base)
        let exe=try script(base,"python peer","#!/usr/bin/python3\nimport json,sys\nprint('1.4.0')\n")
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent("private"))
        let result=try await execute(plan,arguments:["--version"])
        XCTAssertEqual(result.1,0,result.0)
    }
    @MainActor func testPeerScriptVersionWithTypedToolchainAndProbeInputs() async throws {
        let base=try fixture(), a=try authority(base)
        let exe=base.appendingPathComponent("external pi")
        try FileManager.default.copyItem(at:project.appendingPathComponent("Tests/Fixtures/pi_parity_peer.py"),to:exe)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        let inputs=["DEVELOPER_DIR":"/Applications/Xcode.app/Contents/Developer","MILK_PARITY_READY":"1","MILK_COMPAT_LOG":base.appendingPathComponent("peer.jsonl").path,"PATH":"/usr/bin:/bin"]
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent("private"),sourceEnvironment:inputs,explicitEnvironment:inputs,support:[base],runtimeDependencies:PiRuntimeService.supportRoots(executable:exe))
        let result=try await execute(plan,arguments:["--version"])
        XCTAssertEqual(result.1,0,result.0)
        XCTAssertTrue(result.0.contains("1.4.0"),result.0)
    }
    @MainActor func testRealCompatibilityCandidateUsesPrivatePurposeAndNoOrdinaryProfile() async throws {
        let base=try fixture(), ordinary=base.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at:ordinary,withIntermediateDirectories:true)
        try Data("throw Error('must not load')".utf8).write(to:ordinary.appendingPathComponent("extension.ts"))
        try Data(#"{"extensions":["./extension.ts"]}"#.utf8).write(to:ordinary.appendingPathComponent("settings.json"))
        let runtime=PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["PI_CODING_AGENT_DIR":ordinary.path,"MILK_PI_LOCAL_KEY":"synthetic"])
        let a=try authority(base), owner=AgentLifecycleCoordinator()
        let report=try await SandboxLaunchAuthority.$current.withValue(a) { try await PiCompatibilityProbe.inspect(mode:.bundled,runtime:runtime,lifecycle:owner) }
        XCTAssertTrue(report.usable,report.detail); XCTAssertTrue(owner.owned.isEmpty)
    }
    @MainActor func testAuthorityChangeCancelsProbeTimeoutOnlyDoesNot() async throws {
        let base=try fixture(), a=try authority(base)
        let exe=try script(base,"long-probe","#!/bin/sh\nprintf ready; sleep 5\n")
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent("private"))
        try a.settings!.setTimeout(seconds:5); XCTAssertNoThrow(try plan.check())
        let task=Task { try await execute(plan) }
        try await Task.sleep(nanoseconds:200_000_000)
        try a.settings!.setEnabled(false)
        do { _=try await task.value; XCTFail("Old policy probe survived settings change") } catch {}
    }
}

extension SandboxPurposeTests {
    @MainActor func testInstallationTransactionExecutesRealPinnedNativeCandidateInsidePrivateBoundary() async throws {
        let base=try fixture(), a=try authority(base)
        let folder=base.appendingPathComponent("archive/pi"), outside=base.appendingPathComponent("outside-write")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let source=base.appendingPathComponent("candidate.c"), executable=folder.appendingPathComponent("pi")
        let marker=JSONValue.string(outside.path).encodedString.replacingOccurrences(of:"\\/",with:"/")
        let code="""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        int main(int argc,char **argv) {
          if(getenv("MILK_PI_LOCAL_KEY") || getenv("OPENAI_API_KEY")) return 42;
          const char *home=getenv("HOME"), *temp=getenv("TMPDIR"), *profile=getenv("PI_CODING_AGENT_DIR");
          if(!home || !temp || !profile || strcmp(home,temp) || strncmp(profile,home,strlen(home))) return 43;
          char file[8192]; snprintf(file,sizeof(file),"%s/private-proof",home);
          FILE *owned=fopen(file,"w"); if(!owned) return 44; fputs("private",owned); fclose(owned);
          FILE *escape=fopen(\(marker),"w"); if(escape) { fputs("BYPASS",escape); fclose(escape); }
          if(argc>1 && !strcmp(argv[1],"--version")) { puts("1.4.0"); return 0; }
          setvbuf(stdout,NULL,_IONBF,0);
          puts("{\\"type\\":\\"extension_ui_request\\",\\"method\\":\\"setStatus\\",\\"statusKey\\":\\"milk-integration-ready\\",\\"statusText\\":\\"1\\"}");
          char *line=NULL; size_t capacity=0;
          while(getline(&line,&capacity,stdin)>0) {
            char id[128]="", *at=strstr(line,"\\"id\\""); if(!at) return 45;
            at=strchr(at,':')+1; while(*at==' ')at++; if(*at!='\\"')return 46; at++;
            char *end=strchr(at,'\\"'); if(!end || end-at>=sizeof(id))return 47; memcpy(id,at,end-at);
            const char *data=strstr(line,"get_state") ? "{\\"sessionId\\":\\"candidate-fixture\\"}" :
              strstr(line,"get_commands") ? "{\\"commands\\":[]}" :
              strstr(line,"get_available_models") ? "{\\"models\\":[]}" :
              strstr(line,"get_available_thinking_levels") ? "{\\"levels\\":[\\"off\\"]}" : "{\\"messages\\":[]}";
            printf("{\\"type\\":\\"response\\",\\"id\\":\\"%s\\",\\"success\\":true,\\"data\\":%s}\\n",id,data);
          }
          free(line); return 0;
        }
        """
        try Data(code.utf8).write(to:source)
        func command(_ executable: String, _ arguments: [String], directory: URL = base) throws {
            let process=Process(), pipe=Pipe(); process.executableURL=URL(fileURLWithPath:executable); process.arguments=arguments; process.currentDirectoryURL=directory
            process.environment=["PATH":"/usr/bin:/bin","DEVELOPER_DIR":"/Applications/Xcode.app/Contents/Developer","HOME":base.path,"TMPDIR":base.path]
            process.standardOutput=pipe; process.standardError=pipe; try process.run(); let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AgentError.message(String(decoding:data,as:UTF8.self)) }
        }
        try command("/usr/bin/xcrun",["clang","-arch","arm64",source.path,"-o",executable.path])
        let archive=base.appendingPathComponent("candidate.tar")
        try command("/usr/bin/tar",["-cf",archive.path,"pi"],directory:folder.deletingLastPathComponent())
        let notices=base.appendingPathComponent("notices"); try FileManager.default.createDirectory(at:notices,withIntermediateDirectories:true)
        try Data("synthetic local fixture".utf8).write(to:notices.appendingPathComponent("LICENSE"))
        let release=PiCatalogRelease(version:"1.4.0",platform:"darwin",architecture:"arm64",source:URL(string:"https://fixture.invalid/candidate")!,
            artifacts:[.init(url:URL(string:"https://fixture.invalid/candidate.tar")!,sha256:try PiInstallationFiles.digest(archive),binarySuffix:nil,destination:"pi")],
            files:["pi":try PiInstallationFiles.digest(executable)],executables:["pi"],notices:["LICENSE"],provenance:"Disposable compiled native fixture; no network")
        let runtime=PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["MILK_PI_LOCAL_KEY":"synthetic","OPENAI_API_KEY":"synthetic"])
        let manager=PiInstallationManager(store:.init(root:base.appendingPathComponent("managed")),lifecycle:.init(),runtime:runtime,catalog:.init(releases:[release]),notices:notices,sandboxSettings:a.settings,
            download:{ _,target in try FileManager.default.copyItem(at:archive,to:target) })
        let id=try await manager.install()
        XCTAssertEqual(manager.store.state.selected,id)
        XCTAssertTrue(manager.store.state.managed.first?.health.usable == true)
        XCTAssertTrue(manager.lifecycle.owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:outside.path),"Candidate startup escaped its purpose boundary")
        let staged=try FileManager.default.contentsOfDirectory(at:manager.store.staging,includingPropertiesForKeys:nil)
        XCTAssertTrue(staged.isEmpty,"Candidate staging must clean up after contained child exit")
    }
    @MainActor func testEnvironmentSelectorsNeverCreateBroadHomeGrants() async throws {
        let base=try fixture(), a=try authority(base)
        let exe=try script(base,"env-scope","#!/bin/sh\ncat \"$PI_PACKAGE_DIR/input\" 2>/dev/null; printf complete\n")
        let outside=base.appendingPathComponent("not-code"); try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("must-not-read".utf8).write(to:outside.appendingPathComponent("input"))
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent("private"),sourceEnvironment:["PI_PACKAGE_DIR":outside.path,"DEVELOPER_DIR":base.path])
        let result=try await execute(plan)
        XCTAssertEqual(result.1,0,result.0); XCTAssertFalse(result.0.contains("must-not-read"))
    }
    @MainActor func testRPCMissingProfileAndUnknownUtilityPurposeFailClosed() async throws {
        let base=try fixture(), client=PiRPCClient()
        XCTAssertThrowsError(try client.launch(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","exit 0"],workspace:base,environment:[:],sandboxEnabled:true))
        XCTAssertFalse(client.isRunning)
        do { _=try await PiUtilityProcess.execute(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","exit 0"],timeout:1,purpose:.conversation,lifecycle:nil); XCTFail("Unclassified utility launched") } catch {}
    }
}

extension SandboxPurposeTests {
    @MainActor func testInstallationLocalNodeAndModuleGraphIgnoreAmbientPath() async throws {
        guard let node=["/opt/homebrew/bin/node","/usr/local/bin/node"].first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else { throw XCTSkip("Optional locally installed Node is unavailable") }
        let base=try fixture(), a=try authority(base), bin=base.appendingPathComponent("bin"), modules=base.appendingPathComponent("node_modules")
        let package=modules.appendingPathComponent("milk-probe/bin"), dependency=modules.appendingPathComponent("milk-dependency")
        for dir in [bin,package,dependency] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        try FileManager.default.createSymbolicLink(at:bin.appendingPathComponent("node"),withDestinationURL:URL(fileURLWithPath:node))
        let cli=try script(package,"pi.js","#!/usr/bin/env node\nconst fs=require('fs'); fs.writeFileSync(process.env.HOME+'/node-proof','private'); console.log(require('milk-dependency')+' '+new Intl.DateTimeFormat('en-US').format(new Date(0))); if(process.env.MILK_PI_LOCAL_KEY)process.exit(9);\n")
        try Data("module.exports='module-closure';".utf8).write(to:dependency.appendingPathComponent("index.js"))
        let selected=bin.appendingPathComponent("pi"); try FileManager.default.createSymbolicLink(at:selected,withDestinationURL:cli)
        let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:selected,authority:a,root:base.appendingPathComponent("private"),sourceEnvironment:["PATH":".:/untrusted/ambient/bin","MILK_PI_LOCAL_KEY":"synthetic"])
        let result=try await execute(plan)
        XCTAssertEqual(result.1,0,result.0); XCTAssertTrue(result.0.contains("module-closure"),result.0)
        XCTAssertTrue(plan.closure.snapshots.contains { $0.requestedURL.path == bin.appendingPathComponent("node").path })
        XCTAssertTrue(plan.closure.roots.contains { $0.url.path == modules.path && $0.subtree })
        XCTAssertFalse(plan.environment["PATH"]!.contains("untrusted"))
    }
    @MainActor func testPackagePolicyCeilingReadOnlyProjectInactiveAndAlias() async throws {
        let base=try fixture(), workspace=base.appendingPathComponent("workspace"), source=base.appendingPathComponent("input"), target=workspace.appendingPathComponent("profile")
        for dir in [workspace,source,target] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let file=source.appendingPathComponent("source.txt"), alias=target.appendingPathComponent("alias")
        try Data("unchanged".utf8).write(to:file)
        try FileManager.default.linkItem(at:file,to:alias)
        let exe=try script(base,"package-alias","#!/bin/sh\nprintf bad > '"+alias.path+"' 2>/dev/null; printf result\n")
        let a=try authority(base)
        XCTAssertThrowsError(try SandboxPurposePlan.make(purpose:.packageCommand,executable:exe,authority:a,root:base.appendingPathComponent("private"),packageSource:file,target:.init(directory:target,ownership:.milkManaged),project:workspace),"Read-only input and writable target share an inode through different names")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"unchanged")
        try FileManager.default.removeItem(at:alias)
        let readonly=try authority(base) { $0.projects[workspace.path] = .init(access:.readOnly) }
        let writer=try script(base,"project-writer","#!/bin/sh\nprintf bad > \"$PI_CODING_AGENT_DIR/new\" 2>/dev/null; printf result\n")
        let denied=try SandboxPurposePlan.make(purpose:.packageCommand,executable:writer,authority:readonly,root:base.appendingPathComponent("denied"),packageSource:source,target:.init(directory:target,ownership:.sharedExisting),project:workspace)
        _=try await execute(denied); XCTAssertFalse(FileManager.default.fileExists(atPath:target.appendingPathComponent("new").path))
        let inactive=SandboxLaunchAuthority(configuration:a.configuration,isValid:true,inactiveProfiles:[.init(id:"inactive-input",agentID:.pi,url:source,ownership:.existing)])
        let reader=try script(base,"inactive-reader","#!/bin/sh\ncat '"+file.path+"'\n")
        let isolated=try SandboxPurposePlan.make(purpose:.packageCommand,executable:reader,authority:inactive,root:base.appendingPathComponent("isolated"),packageSource:source,target:.init(directory:target,ownership:.milkManaged))
        let noRead=try await execute(isolated); XCTAssertNotEqual(noRead.1,0); XCTAssertFalse(noRead.0.contains("unchanged"))
    }
}


extension SandboxPurposeTests {
    @MainActor func testPreviewInspectionUsesPrivateHomeAndLeavesSelectedProfileUntouched() async throws {
        let base=try fixture(), a=try authority(base), ordinary=base.appendingPathComponent("ordinary"), workspace=base.appendingPathComponent("project")
        for dir in [ordinary,workspace] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let data=ordinary.appendingPathComponent("retain.txt"); try Data("user-owned".utf8).write(to:data)
        let exe=base.appendingPathComponent("preview-peer")
        var body=try String(contentsOf:project.appendingPathComponent("Tests/Fixtures/pi_parity_peer.py"),encoding:.utf8)
        body=body.replacingOccurrences(of:"log(\"launch\", args=",with:"if os.environ.get('MILK_PREVIEW_DISCOVERY') == '1':\n    assert os.environ['HOME'] == os.environ['PI_CODING_AGENT_DIR']\n    assert 'Milk-Inspection-' in os.environ['HOME']\nlog(\"launch\", args=")
        try Data(body.utf8).write(to:exe); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        let runtime=PiRuntimeService(resources:project.appendingPathComponent("Runtime"),environmentOverrides:["HOME":base.path,"PI_CODING_AGENT_DIR":ordinary.path,"MILK_PARITY_READY":"1"],probeEnvironmentOverrides:["MILK_PARITY_READY":"1"])
        var config=AgentConfiguration(); config.runtime = .external(exe)
        let backend=PiBackend(sandboxSettings:a.settings!,runtime:runtime,discoveryOnly:true,configuration:config)
        var ready: RuntimeStatus?
        backend.onEvent={ if case .runtime(let value)=$0, value.phase == .ready { ready=value } }
        do { try await backend.start(workspace:workspace,session:.init(id:1,title:"inspection")) }
        catch { try? await backend.shutdownAndWait(); throw error }
        let status=try XCTUnwrap(ready), ephemeral=try XCTUnwrap(status.dataProfile?.directory)
        XCTAssertEqual(status.dataProfile?.ownership,.ephemeralMilk)
        XCTAssertNotEqual(ephemeral,ordinary); XCTAssertTrue(status.detail.contains("Sandbox ON"))
        try await backend.shutdownAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath:ephemeral.path))
        XCTAssertEqual(try String(contentsOf:data,encoding:.utf8),"user-owned")
    }
}
