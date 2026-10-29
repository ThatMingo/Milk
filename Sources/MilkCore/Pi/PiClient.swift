import Foundation

public enum PiEvent: Sendable { case record(JSONValue), diagnostic, failed(String), exited(Int32) }

public actor PiClient {
    public nonisolated let events: AsyncStream<PiEvent>
    private let continuation: AsyncStream<PiEvent>.Continuation
    private let child: ChildProcess
    private var reader: Task<Void, Never>?
    private var framer = JSONLFramer()
    private struct Pending { let reply: CheckedContinuation<JSONValue, any Error>; let deadline: Task<Void, Never> }
    private var requests: [String: Pending] = [:]
    private var exited = false

    public init(child: ChildProcess = ChildProcess()) {
        self.child = child; (events, continuation) = AsyncStream.makeStream()
    }
    public func start(_ configuration: ProcessConfiguration) throws {
        guard reader == nil else { throw MilkError.message("Pi client already started") }
        try child.start(configuration)
        reader = Task { [weak self, child] in
            for await event in child.events { await self?.receive(event) }
        }
    }
    private func receive(_ event: ProcessEvent) {
        switch event {
        case .output(let data):
            do {
                for record in try framer.append(data) {
                    if record["type"].string == "response", let id = record["id"].string, let pending = requests.removeValue(forKey: id) {
                        pending.deadline.cancel()
                        if record["success"].bool == true { pending.reply.resume(returning: record["data"]) }
                        else { pending.reply.resume(throwing: MilkError.message(record["error"].string ?? "Pi command failed")) }
                    } else { continuation.yield(.record(record)) }
                }
            } catch { continuation.yield(.failed(error.localizedDescription)); failPending(error); child.terminate() }
        case .diagnostic: continuation.yield(.diagnostic) // Raw stderr may contain secrets; never persist it.
        case .exited(let code):
            exited = true
            do { try framer.finish() } catch { continuation.yield(.failed(error.localizedDescription)) }
            failPending(MilkError.message("Pi exited (\(code))")); continuation.yield(.exited(code)); continuation.finish()
        }
    }
    private func failPending(_ error: any Error) {
        let pending = requests.values; requests.removeAll()
        for request in pending { request.deadline.cancel(); request.reply.resume(throwing: error) }
    }
    private func cancel(_ id: String, error: any Error) {
        guard let pending = requests.removeValue(forKey: id) else { return }
        pending.deadline.cancel(); pending.reply.resume(throwing: error)
    }
    public func request(_ type: String, fields: [String: JSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { reply in
                if exited { reply.resume(throwing: MilkError.message("Pi is not running")); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout); await self?.cancel(id, error: MilkError.message("Pi \(type) timed out")) } catch {}
                }
                requests[id] = Pending(reply: reply, deadline: deadline)
                Task {
                    do {
                        var record = fields; record["type"] = .string(type); record["id"] = .string(id)
                        try await send(record)
                    } catch { cancel(id, error: error) }
                }
            }
        } onCancel: { Task { await self.cancel(id, error: CancellationError()) } }
    }
    public func send(_ record: [String: JSONValue]) async throws {
        var bytes = try JSONEncoder().encode(JSONValue.object(record)); bytes.append(10)
        try await child.write(bytes)
    }
    public func stop() async throws {
        _ = try await request("clear_queue")
        _ = try await request("abort", timeout: .seconds(15))
    }
    public func shutdown() async {
        if exited { return }
        _ = try? await request("clear_queue", timeout: .seconds(2))
        _ = try? await request("abort", timeout: .seconds(5))
        child.closeInput()
        for _ in 0..<30 { if !child.isRunning { return }; try? await Task.sleep(for: .milliseconds(100)) }
        child.terminate()
        for _ in 0..<20 { if !child.isRunning { return }; try? await Task.sleep(for: .milliseconds(100)) }
        child.kill()
    }
}
