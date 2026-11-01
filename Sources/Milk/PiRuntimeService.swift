import Foundation
import CryptoKit
import Darwin

struct PiRuntimeManifest: Codable {
    var version: String
    var archiveSHA256: String
    var executableSHA256: String
    var source: String
    var tools: [Tool]
    var runtimeFiles: [String: String]
    struct Tool: Codable { var name: String; var version: String; var executableSHA256: String }
}
struct PiRuntimeLocation {
    var executable: URL
    var integration: URL
    var manifest: PiRuntimeManifest?
    var bundled: Bool
}

/// Resolves all immutable runtime resources relative to the installed application.
/// Tests/SwiftPM can explicitly inject a resource root; production has no developer path fallback.
struct PiRuntimeService {
    let resources: URL
    let environmentOverrides: [String: String]
    let allowsBundledFixture: Bool
    init(resources: URL? = nil, environmentOverrides: [String: String] = [:], allowBundledFixture: Bool? = nil) {
        self.resources = resources ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.environmentOverrides = environmentOverrides
        allowsBundledFixture = allowBundledFixture ?? (resources != nil)
    }
    var bundledVersion: String? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("PiRuntime/runtime-manifest.json")) else { return nil }
        return (try? JSONDecoder().decode(PiRuntimeManifest.self, from: data))?.version
    }
    func locate(_ mode: PiRuntimeMode) throws -> PiRuntimeLocation {
        if mode.isBundled && !allowsBundledFixture { throw AgentError.message("Pi is not installed. Open Settings → Agents to install Pi or use an existing installation.") }
        let root = resources.appendingPathComponent("PiRuntime")
        var manifest: PiRuntimeManifest?
        if mode.isBundled {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("runtime-manifest.json")),
                  let value = try? JSONDecoder().decode(PiRuntimeManifest.self, from: data) else {
                throw AgentError.message("Milk's bundled Pi manifest is missing or corrupt. Reinstall Milk.")
            }
            manifest = value
        }
        let executable: URL
        switch mode { case .bundled: executable = root.appendingPathComponent("pi"); case .external(let path): executable = path }
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentError.message(mode.isBundled ? "Bundled Pi is missing or not executable. Reinstall Milk." : "The selected external Pi executable is missing or not executable.")
        }
        if mode.isBundled, let manifest {
            func verify(_ url: URL, expected: String) throws {
                guard let data = try? Data(contentsOf: url), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                    throw AgentError.message("Bundled runtime integrity check failed for \(url.lastPathComponent). Reinstall Milk.")
                }
            }
            try verify(executable, expected: manifest.executableSHA256)
            for tool in manifest.tools {
                let url = root.appendingPathComponent("bin").appendingPathComponent(tool.name)
                guard FileManager.default.isExecutableFile(atPath: url.path) else { throw AgentError.message("Bundled Pi dependency \(tool.name) is missing or not executable. Reinstall Milk.") }
                try verify(url, expected: tool.executableSHA256)
            }
            for (name, digest) in manifest.runtimeFiles { try verify(root.appendingPathComponent(name), expected: digest) }
        }
        let integration = resources.appendingPathComponent("MilkPiIntegration.ts")
        guard FileManager.default.fileExists(atPath: integration.path) else { throw AgentError.message("Milk's Pi integration extension is missing. Reinstall Milk.") }
        return PiRuntimeLocation(executable: executable, integration: integration, manifest: manifest, bundled: mode.isBundled)
    }
    func version(of executable: URL, lifecycle: AgentLifecycleCoordinator? = nil, environment: [String: String]? = nil, directory: URL? = nil) async throws -> String {
        let (data, status) = try await PiUtilityProcess.execute(executable: executable, arguments: ["--version"], directory: directory, environment: environment, timeout: 8, purpose: .versionProbe, lifecycle: lifecycle)
        guard status == 0, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AgentError.message("Pi version check failed. Check the executable and its runtime dependencies.")
        }
        return text
    }
}

/// LF byte framing preserves split UTF-8 scalars and Unicode separators inside JSON strings.
struct PiJSONLFramer {
    private var buffer = Data()
    private var scanned = 0
    private(set) var scannedByteCount = 0
    static let maximumRecordBytes = 32 * 1024 * 1024
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = [], consumed = 0
        try buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var search = scanned
            while search < bytes.count {
                let remaining = bytes.count - search
                guard let newline = memchr(base.advanced(by: search), 10, remaining) else {
                    scannedByteCount += remaining
                    break
                }
                let end = base.distance(to: UnsafeRawPointer(newline))
                scannedByteCount += end - search + 1
                let lineEnd = end > consumed && bytes[end - 1] == 13 ? end - 1 : end
                guard lineEnd - consumed <= Self.maximumRecordBytes else { throw AgentError.message("Pi sent an oversized RPC record.") }
                if lineEnd > consumed { lines.append(Data(bytes: base.advanced(by: consumed), count: lineEnd - consumed)) }
                consumed = end + 1; search = consumed
            }
        }
        // A growing, unfinished history record is scanned once, not from its
        // beginning on every pipe read. Compact only after extracting all lines.
        scanned = buffer.count - consumed
        if consumed > 0 { buffer.removeFirst(consumed) }
        guard buffer.count <= Self.maximumRecordBytes else { throw AgentError.message("Pi sent an oversized unfinished RPC record.") }
        return lines
    }
    var hasPartialRecord: Bool { !buffer.isEmpty }
}

/// One decoder per stdout reader. Framing and JSON allocation stay off the main
/// actor; ordered domain delivery and request continuations remain on it.
struct PiRPCReadBatch {
    var records: [JSONValue] = []
    var failure: String?
}
struct PiRPCRecordDecoder {
    private var framer = PiJSONLFramer()
    var hasPartialRecord: Bool { framer.hasPartialRecord }
    mutating func append(_ data: Data) -> PiRPCReadBatch {
        let framing = ChatRenderMetrics.begin()
        let lines: [Data]
        do { lines = try framer.append(data) }
        catch { return .init(failure: error.localizedDescription) }
        ChatRenderMetrics.end("rpc.frame.worker", framing, units: data.count)
        var batch = PiRPCReadBatch()
        for line in lines {
            let metric = ChatRenderMetrics.begin()
            defer { ChatRenderMetrics.end("rpc.decode.worker", metric, units: line.count) }
            let record: JSONValue
            do { record = try JSONDecoder().decode(JSONValue.self, from: line) }
            catch { batch.failure = "Pi sent malformed RPC JSON. Restart the runtime to reconnect."; return batch }
            guard record["type"].string != nil else { batch.failure = "Pi sent an RPC record without a type."; return batch }
            batch.records.append(record)
        }
        return batch
    }
}

/// Owns one process, its async request table, deadlines, byte framing, stderr, and shutdown.
@MainActor final class PiRPCClient {
    var onRecord: ((JSONValue) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var stderr = ""
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var closing = false
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private let writer = DispatchQueue(label: "dev.milk.pi.stdin")
    var isRunning: Bool { process?.isRunning == true && !closing }

    func launch(executable: URL, arguments: [String], workspace: URL, environment: [String: String]) throws {
        guard process == nil else { throw AgentError.message("Pi is already started.") }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        child.executableURL = executable; child.arguments = arguments; child.currentDirectoryURL = workspace
        child.environment = environment; child.standardInput = stdin; child.standardOutput = stdout; child.standardError = errors
        try child.run()
        process = child; input = stdin.fileHandleForWriting; closing = false
        let token = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = stdout.fileHandleForReading
            var decoder = PiRPCRecordDecoder()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                let batch = decoder.append(data)
                if !batch.records.isEmpty || batch.failure != nil {
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, !self.closing else { return }
                        self.receive(batch.records, generation: token)
                        if let failure = batch.failure, !self.closing { self.fail(failure) }
                    }
                }
                if batch.failure != nil { break }
            }
            child.waitUntilExit()
            let partial = decoder.hasPartialRecord
            DispatchQueue.main.async { self?.exited(child.terminationStatus, generation: token, hasPartialRecord: partial) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reader = errors.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.stderr = String((self.stderr + String(decoding: data, as: UTF8.self)).suffix(16384))
                }
            }
        }
    }
    func request(_ type: String, _ fields: [String: JSONValue] = [:], timeout: Double = 30) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(id, .failure(AgentError.message("Pi did not acknowledge \(type) within \(Int(timeout)) seconds.")))
                }
                do { try write(fields.merging(["type": .string(type), "id": .string(id)]) { _, new in new }) }
                catch { finish(id, .failure(error)) }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.finish(id, .failure(CancellationError())) } })
    }
    func write(_ object: [String: JSONValue]) throws {
        guard isRunning, let input else { throw AgentError.message("Pi is disconnected. Restart the runtime to reconnect.") }
        var data = try JSONEncoder().encode(JSONValue.object(object)); data.append(10)
        let token = generation
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch { DispatchQueue.main.async { guard self?.generation == token else { return }; self?.fail("Pi stdin failed: \(error.localizedDescription)") } }
        }
    }
    private func receive(_ records: [JSONValue], generation token: UUID) {
        guard token == generation, !closing else { return }
        let metric = ChatRenderMetrics.begin()
        defer { ChatRenderMetrics.end("rpc.deliver.main", metric, units: records.count) }
        do {
            for record in records {
                if record["type"].string == "response" {
                    guard let id = record["id"].string else { throw AgentError.message(record["error"].string ?? "Pi returned an uncorrelated protocol error.") }
                    if record["success"].bool { finish(id, .success(record["data"])) }
                    else { finish(id, .failure(AgentError.message(record["error"].string ?? "Pi rejected the request."))) }
                } else { onRecord?(record) }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func finish(_ id: String, _ result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func fail(_ text: String) {
        for id in Array(pending.keys) { finish(id, .failure(AgentError.message(text))) }
        onFailure?(text); shutdown()
    }
    private func exited(_ code: Int32, generation token: UUID, hasPartialRecord: Bool) {
        guard generation == token else { return }
        let expected = closing
        process = nil; input = nil
        let message = "Pi exited (\(code))." + (stderr.isEmpty ? "" : " " + stderr)
        for id in Array(pending.keys) { finish(id, .failure(AgentError.message(message))) }
        if !expected { onFailure?(hasPartialRecord ? "Pi exited during an RPC record. \(message)" : message) }
    }
    func shutdown() {
        guard !closing else { return }; closing = true
        for id in Array(pending.keys) { finish(id, .failure(AgentError.message("Pi runtime closed."))) }
        let handle = input; input = nil
        writer.async { try? handle?.close() } // EOF is Pi's supported graceful shutdown.
        if let child = process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { child.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    func shutdownAndWait() async throws {
        let child = process
        shutdown()
        let deadline = Date().addingTimeInterval(8)
        while child?.isRunning == true {
            guard Date() < deadline else { throw AgentError.message("Pi has not exited. Its saved history was not deleted; try again.") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if let child {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { child.waitUntilExit(); continuation.resume() }
            }
        }
    }
    deinit { if let process, process.isRunning { process.terminate() } }
}
