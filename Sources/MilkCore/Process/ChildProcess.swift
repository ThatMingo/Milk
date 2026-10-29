import Foundation

public struct ProcessConfiguration: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var directory: URL?
    public var environment: [String: String]
    public init(executable: URL, arguments: [String] = [], directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.arguments = arguments; self.directory = directory; self.environment = environment
    }
}

public enum ProcessEvent: Sendable { case output(Data), diagnostic(Data), exited(Int32) }

/// Owns exactly one subprocess. Blocking reads/writes run on dedicated queues, never the UI actor.
public final class ChildProcess: @unchecked Sendable {
    public let events: AsyncStream<ProcessEvent>
    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe(), error = Pipe()
    private let writes = DispatchQueue(label: "Milk.process.stdin")
    private let lock = NSLock()
    private var started = false
    private var inputClosed = false

    public init() { (events, continuation) = AsyncStream.makeStream() }
    public func start(_ configuration: ProcessConfiguration) throws {
        try lock.withLock {
            guard !started else { throw MilkError.message("Process already started") }
            process.executableURL = configuration.executable; process.arguments = configuration.arguments
            process.currentDirectoryURL = configuration.directory; process.environment = configuration.environment
            process.standardInput = input; process.standardOutput = output; process.standardError = error
            try process.run(); started = true
        }
        // Drain both descriptors before publishing exit; never lose trailing protocol records.
        let group = DispatchGroup()
        for (handle, diagnostic) in [(output.fileHandleForReading, false), (error.fileHandleForReading, true)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    let data = Data(buffer.prefix(count))
                    continuation.yield(diagnostic ? .diagnostic(data) : .output(data))
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit(); group.wait()
            continuation.yield(.exited(process.terminationStatus)); continuation.finish()
            closeInput()
        }
    }
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
            writes.async { [self] in
                do {
                    try lock.withLock {
                        guard started, !inputClosed, process.isRunning else { throw MilkError.message("Process input is closed") }
                        try input.fileHandleForWriting.write(contentsOf: data)
                    }
                    reply.resume()
                } catch { reply.resume(throwing: error) }
            }
        }
    }
    public func closeInput() { lock.withLock { if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() } } }
    public func terminate() { lock.withLock { if started && process.isRunning { process.terminate() } } }
    public func kill() { lock.withLock { if started && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } } }
    public var isRunning: Bool { lock.withLock { started && process.isRunning } }
}

public struct CommandResult: Sendable { public var output: Data; public var error: Data; public var status: Int32 }
public enum CommandRunner {
    public static func run(_ config: ProcessConfiguration, timeout: Duration = .seconds(30)) async throws -> CommandResult {
        let child = ChildProcess(); try child.start(config); child.closeInput()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    var out = Data(), err = Data(); var status: Int32 = -1
                    for await event in child.events {
                        switch event {
                        case .output(let data): out.append(data)
                        case .diagnostic(let data): err.append(data)
                        case .exited(let code): status = code
                        }
                    }
                    return CommandResult(output: out, error: err, status: status)
                }
                group.addTask { try await Task.sleep(for: timeout); child.kill(); throw MilkError.message("Command timed out") }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { child.kill() }
    }
}
