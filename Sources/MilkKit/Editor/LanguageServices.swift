import Foundation
import MilkCore
import LanguageServerProtocol
import JSONRPC

public struct LSPFramer: Sendable {
    private var data = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [MilkCore.JSONValue] {
        data.append(bytes); var result: [MilkCore.JSONValue] = []
        let separator = Data("\r\n\r\n".utf8)
        while let header = data.range(of: separator) {
            let fields = String(decoding: data[..<header.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard let value = fields.first(where: { $0.lowercased().hasPrefix("content-length:") })?.split(separator: ":", maxSplits: 1).last,
                  let count = Int(value.trimmingCharacters(in: .whitespaces)), count >= 0, count < 32 * 1024 * 1024 else { throw MilkError.message("Invalid LSP Content-Length") }
            let start = header.upperBound; guard data.distance(from: start, to: data.endIndex) >= count else { break }
            let end = data.index(start, offsetBy: count)
            result.append(try JSONDecoder().decode(MilkCore.JSONValue.self, from: data[start..<end])); data.removeSubrange(..<end)
        }
        guard data.count < 32 * 1024 * 1024 else { throw MilkError.message("LSP frame exceeds limit") }
        return result
    }
}
public actor LanguageServerClient {
    public nonisolated let events: AsyncStream<MilkCore.JSONValue>
    private let continuation: AsyncStream<MilkCore.JSONValue>.Continuation
    private var child: ChildProcess?
    private var reader: Task<Void, Never>?
    private var framer = LSPFramer()
    private var nextID = 0
    private var initialized = false
    public init() { (events, continuation) = AsyncStream.makeStream() }
    public func start(executable: URL, workspace: URL) async throws {
        let process = ChildProcess(); try process.start(.init(executable: executable, directory: workspace)); child = process
        reader = Task { [weak self] in for await event in process.events { await self?.consume(event) } }
        try await request("initialize", params: .object([
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)), "rootUri": .string(workspace.absoluteString),
            "capabilities": .object(["general": .object(["positionEncodings": .array([.string("utf-16")])])])
        ]))
        for _ in 0..<100 {
            if initialized { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        shutdown(); throw MilkError.message("Language server initialization timed out")
    }
    private func consume(_ event: ProcessEvent) async {
        switch event {
        case .output(let bytes):
            do {
                for record in try framer.append(bytes) {
                    continuation.yield(record)
                    if record["id"] == .number(1), record["result"] != .null { try await notify("initialized", params: .object([:])); initialized = true }
                    if record["method"].string != nil && record["id"] != .null {
                        try await send(.object(["jsonrpc": .string("2.0"), "id": record["id"], "error": .object(["code": .number(-32601), "message": .string("Client method not supported")])]))
                    }
                }
            } catch { continuation.yield(.object(["milkError": .string("Language server protocol failure")])); child?.terminate() }
        case .exited: continuation.finish()
        case .diagnostic: break
        }
    }
    @discardableResult public func request(_ method: String, params: MilkCore.JSONValue) async throws -> Int {
        nextID += 1; let id = nextID
        let request = JSONRPCRequest(id: id, method: method, params: params)
        try await write(JSONEncoder().encode(request)); return id
    }
    public func notify(_ method: String, params: MilkCore.JSONValue) async throws {
        try await write(JSONEncoder().encode(JSONRPCNotification(method: method, params: params)))
    }
    private func send(_ value: MilkCore.JSONValue) async throws {
        try await write(JSONEncoder().encode(value))
    }
    private func write(_ bytes: Data) async throws {
        guard let child else { throw MilkError.message("Language server is not running") }
        try await child.write(Data("Content-Length: \(bytes.count)\r\n\r\n".utf8) + bytes)
    }
    public func shutdown() { child?.closeInput(); child?.terminate(); reader?.cancel() }
    public static func position(in text: String, utf16Offset: Int) -> Position {
        let prefix = (text as NSString).substring(to: min(max(0, utf16Offset), text.utf16.count))
        let lines = prefix.components(separatedBy: "\n")
        return Position(line: lines.count - 1, character: lines.last?.utf16.count ?? 0)
    }
}
public actor LanguageServiceManager {
    private var servers: [String: LanguageServerClient] = [:]
    public init() {}
    public func connect(language: String, executable: URL, workspace: URL) async throws -> LanguageServerClient {
        let key = workspace.path + ":" + language
        if let existing = servers[key] { return existing }
        let client = LanguageServerClient(); try await client.start(executable: executable, workspace: workspace); servers[key] = client
        return client
    }
    public func shutdown() async { for client in servers.values { await client.shutdown() }; servers.removeAll() }
}
