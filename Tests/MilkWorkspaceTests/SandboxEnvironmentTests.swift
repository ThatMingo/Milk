import XCTest
import Darwin
@testable import Milk

final class SandboxEnvironmentTests: XCTestCase {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("Milk-Environment-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:value) }; return value
    }
    func testRuntimePreservesSelectedProfileAndDeclaredProviderInputsWithoutAmbientInjection() throws {
        let root = try root(), home = root.appendingPathComponent("home"), profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at:profile,withIntermediateDirectories:true)
        try Data(#"{"providers":{"custom":{"description":"$UNRELATED_SECRET","models":[{"id":"$UNRELATED_SECRET"}],"apiKey":"$CUSTOM_PROVIDER_TOKEN","headers":{"X-Other":"${CUSTOM_HEADER}","X-Evil":"$NODE_OPTIONS"}}}}"#.utf8).write(to:profile.appendingPathComponent("models.json"))
        try Data(#"{"mcpServers":{"docs":{"description":"$UNRELATED_SECRET","env":{"TOKEN":"${DOCS_TOKEN}"}}}}"#.utf8).write(to:profile.appendingPathComponent("mcp.json"))
        let source = ["HOME":home.path,"TMPDIR":root.path,"PI_CODING_AGENT_DIR":"/wrong-profile","PATH":":relative:.:/custom/bin:/usr/bin",
                      "OPENAI_API_KEY":"synthetic-openai","CUSTOM_PROVIDER_TOKEN":"synthetic-custom","CUSTOM_HEADER":"header","DOCS_TOKEN":"synthetic-mcp",
                      "UNRELATED_SECRET":"drop","MILK_PI_LOCAL_KEY":"stale-ambient","MILK_PI_LOCAL_NO_AUTH":"1","MILK_SANDBOX_ON":"1",
                      "DYLD_INSERT_LIBRARIES":"drop","NODE_OPTIONS":"drop","BASH_ENV":"drop","GIT_CONFIG_COUNT":"1","HTTPS_PROXY":"http://localhost:3128"]
        let environment = try PiEnvironment.runtime(source:source,explicit:[:],profile:.init(directory:profile,ownership:.sharedExisting),support:[root.appendingPathComponent("selected")])
        XCTAssertEqual(environment["HOME"],home.path); XCTAssertEqual(environment["PI_CODING_AGENT_DIR"],profile.path)
        for key in ["OPENAI_API_KEY","CUSTOM_PROVIDER_TOKEN","CUSTOM_HEADER","DOCS_TOKEN","HTTPS_PROXY"] { XCTAssertEqual(environment[key],source[key]) }
        for key in ["UNRELATED_SECRET","MILK_PI_LOCAL_KEY","MILK_PI_LOCAL_NO_AUTH","MILK_SANDBOX_ON","DYLD_INSERT_LIBRARIES","NODE_OPTIONS","BASH_ENV","GIT_CONFIG_COUNT"] { XCTAssertNil(environment[key],key) }
        let paths = try XCTUnwrap(environment["PATH"]).components(separatedBy:":")
        XCTAssertEqual(paths.first,root.appendingPathComponent("selected").path)
        XCTAssertTrue(paths.contains("/custom/bin")); XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/") })
    }
    func testExecutorAndProbeExcludeRuntimeSecretsAndBootstrapState() throws {
        let work = try root()
        let source = ["MILK_PI_LOCAL_KEY":"synthetic-local","OPENAI_API_KEY":"synthetic-other","HTTP_PROXY":"http://secret:password@localhost", "HOME":"/user-home","PATH":".:/usr/bin","PYTHONPATH":"/inject","BASH_ENV":"/inject","GIT_DIR":"/wrong"]
        for result in [PiEnvironment.executor(work:work,support:[]),PiEnvironment.probe(source:source,explicit:source,work:work,support:[])] {
            for key in ["MILK_PI_LOCAL_KEY","OPENAI_API_KEY","HTTP_PROXY","PYTHONPATH","BASH_ENV","GIT_DIR"] { XCTAssertNil(result[key],key) }
            XCTAssertEqual(result["HOME"],work.path); XCTAssertEqual(result["TMPDIR"],work.path)
            XCTAssertEqual(result["PI_CODING_AGENT_DIR"],work.appendingPathComponent("profile").path)
        }
    }
    func testExplicitLauncherInputsNeverOverrideMilkAuthorityOrStartupFiltering() throws {
        let work = try root()
        let overrides = ["FIXTURE_CONTROL":"true","MILK_PARITY_LOG":"synthetic-path","MILK_PI_LOCAL_KEY":"stale","MILK_SANDBOX_ON":"0","NODE_OPTIONS":"--require=evil","ENV":"evil","GIT_CONFIG_GLOBAL":"evil"]
        let runtime = try PiEnvironment.runtime(source:overrides,explicit:overrides,profile:.init(directory:work,ownership:.milkManaged),support:[])
        let probe = PiEnvironment.probe(source:runtime,explicit:overrides,work:work,support:[])
        for result in [runtime,probe] {
            XCTAssertEqual(result["FIXTURE_CONTROL"],"true"); XCTAssertEqual(result["MILK_PARITY_LOG"],"synthetic-path")
            for key in ["MILK_PI_LOCAL_KEY","MILK_SANDBOX_ON","NODE_OPTIONS","ENV","GIT_CONFIG_GLOBAL"] { XCTAssertNil(result[key],key) }
        }
    }
    func testInvalidHomeAndNulInputsDoNotEnterProcessEnvironment() throws {
        let work = try root(), profile = AgentDataProfile(directory:work,ownership:.sharedExisting)
        for home in ["relative", "/home\0wrong"] {
            XCTAssertThrowsError(try PiEnvironment.runtime(source:["HOME":home],explicit:[:],profile:profile,support:[]))
        }
        let result = try PiEnvironment.runtime(source:["OPENAI_API_KEY":"invalid\0value"],explicit:["BAD=NAME":"value"],profile:profile,support:[])
        XCTAssertNil(result["OPENAI_API_KEY"]); XCTAssertNil(result["BAD=NAME"])
        let generic = SandboxEnvironment.execution(home:work,temporary:work,support:[])
        XCTAssertFalse(generic.keys.contains { $0.hasPrefix("PI_") || $0.hasPrefix("MILK_") })
    }
    func testUnsafeConfigurationFilesAndSupportPathsFailClosed() throws {
        let work = try root(), profile = AgentDataProfile(directory:work,ownership:.sharedExisting)
        let fifo = work.appendingPathComponent("mcp.json")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try PiEnvironment.runtime(source:[:],explicit:[:],profile:profile,support:[]))
        try FileManager.default.removeItem(at:fifo)
        XCTAssertThrowsError(try PiEnvironment.runtime(source:[:],explicit:[:],profile:profile,support:[work.appendingPathComponent("unsafe:.")]))
        XCTAssertFalse(SandboxEnvironment.path(support:[work.appendingPathComponent("unsafe:.")]).components(separatedBy:":").contains("."))
    }
    func testHostSelectedDeveloperDirectoryIsTypedAndRetainedWithoutOtherAmbientState() throws {
        let work = try root()
        let selected = try SandboxToolchainEnvironment(source:["DEVELOPER_DIR":work.path,"OPENAI_API_KEY":"synthetic-provider","BASH_ENV":"injected"])
        let expected = try SandboxPathResolver().resolve(work).canonicalURL.path
        let worker = PiEnvironment.executor(work:work,support:[],toolchain:selected)
        XCTAssertEqual(worker["DEVELOPER_DIR"],expected); XCTAssertNil(worker["OPENAI_API_KEY"]); XCTAssertNil(worker["BASH_ENV"])
        XCTAssertThrowsError(try SandboxToolchainEnvironment(source:["DEVELOPER_DIR":"relative"]))
        let runtime = try PiEnvironment.runtime(source:["DEVELOPER_DIR":work.path],explicit:[:],profile:.init(directory:work,ownership:.sharedExisting),support:[])
        XCTAssertEqual(runtime["DEVELOPER_DIR"],expected)
    }
    func testDiagnosticRedactionIncludesChunkSuffixAndPreservesNullErrorFields() {
        let redactor = RuntimeDiagnosticRedactor(environment:["MILK_PI_LOCAL_KEY":"synthetic-local-secret"])
        XCTAssertFalse(redactor.text("request failed: synthetic-local-secret").contains("synthetic-local-secret"))
        XCTAssertEqual(redactor.text("partial synthetic-local-"),"partial [redacted]")
        XCTAssertEqual(redactor.diagnostics(.object(["error":.null])),.object(["error":.null]))
        XCTAssertEqual(redactor.diagnostics(.object(["error":.string("synthetic-local-secret")])),.object(["error":.string("[redacted]")]))
    }
    @MainActor func testActualRPCErrorsAndStderrRedactAdmittedCredentials() async throws {
        let work = try root(), script = work.appendingPathComponent("peer.py")
        let code = """
        import os,sys,json,time
        key=os.environ['MILK_PI_LOCAL_KEY']
        sys.stderr.write(key[:8]);sys.stderr.flush();time.sleep(.05)
        sys.stderr.write(key[8:]);sys.stderr.flush()
        for line in sys.stdin:
            request=json.loads(line)
            print(json.dumps({'type':'extension_error','error':key}),flush=True)
            print(json.dumps({'type':'response','id':request['id'],'success':False,'error':key}),flush=True)
        """
        try Data(code.utf8).write(to:script)
        let key = "synthetic-runtime-secret", client = PiRPCClient()
        var errorEvent = ""
        client.onRecord = { if $0["type"].string == "extension_error" { errorEvent = $0["error"].string ?? "" } }
        defer { client.shutdown() }
        try client.launch(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[script.path],workspace:work,environment:["MILK_PI_LOCAL_KEY":key,"PATH":"/usr/bin:/bin"])
        do { _ = try await client.request("get_state"); XCTFail("Fixture error not returned") }
        catch { XCTAssertFalse(error.localizedDescription.contains(key)); XCTAssertTrue(error.localizedDescription.contains("[redacted]")) }
        XCTAssertEqual(errorEvent,"[redacted]"); XCTAssertFalse(client.stderr.contains(key))
        try await client.shutdownAndWait()
    }
    @MainActor func testRuntimeOnlyCustomCredentialDoesNotReachVersionOrCompatibilityHelpers() async throws {
        let work = try root(), profile = work.appendingPathComponent("profile"), resources = work.appendingPathComponent("resources")
        for url in [profile,resources] { try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true) }
        try Data("// no RPC used".utf8).write(to:resources.appendingPathComponent("MilkPiIntegration.ts"))
        let executable = work.appendingPathComponent("selected-pi")
        try Data("#!/bin/sh\nif test -n \"$CUSTOM_PROVIDER_AUTH\"; then exit 73; fi\nprintf 1.4.0\n".utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
        try Data(#"{"providers":{"custom":{"apiKey":"$CUSTOM_PROVIDER_AUTH"}}}"#.utf8).write(to:profile.appendingPathComponent("models.json"))
        let runtime = PiRuntimeService(resources:resources,environmentOverrides:["PI_CODING_AGENT_DIR":profile.path,"CUSTOM_PROVIDER_AUTH":"synthetic-custom-credential"])
        let launch = try await PiLaunchResolver(runtime:runtime).resolve(.external(executable),lifecycle:nil)
        XCTAssertEqual(launch.environment["CUSTOM_PROVIDER_AUTH"],"synthetic-custom-credential")
        let isolated = try await PiLaunchResolver(runtime:runtime).resolve(runtimeRecord(executable),lifecycle:nil,probeDirectory:work)
        XCTAssertNil(isolated.environment["CUSTOM_PROVIDER_AUTH"])
        XCTAssertNil(isolated.environment["MILK_PI_LOCAL_KEY"])
    }
    private func runtimeRecord(_ executable: URL) -> AgentInstallationRecord {
        .init(id:.init(rawValue:"synthetic-external"),agentID:.pi,ownership:.external,source:.userSelected,executable:executable)
    }
}
