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
        printf outside > '\(forbidden.path)' 2>/dev/null
        printf 'home=%s tmp=%s profile=%s' "$HOME" "$TMPDIR" "$PI_CODING_AGENT_DIR"
        """)
        for enabled in [true,false] {
            let a=try authority(base,enabled:enabled)
            let plan=try SandboxPurposePlan.make(purpose:.versionProbe,executable:exe,authority:a,root:base.appendingPathComponent(UUID().uuidString),sourceEnvironment:["MILK_PI_LOCAL_KEY":"synthetic","OPENAI_API_KEY":"synthetic","BASH_ENV":"/bad","PATH":".:relative:/usr/bin"])
            let result=try await execute(plan); XCTAssertEqual(result.1,0,result.0)
            XCTAssertTrue(result.0.contains(plan.root.path),result.0)
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
