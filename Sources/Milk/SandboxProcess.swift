import Foundation
import Darwin
import MilkPTY

/// Owns a child/group identity through final signals and reap. No Foundation child reaper.
final class SandboxProcess: @unchecked Sendable {
    private let condition = NSCondition()
    private var pid: pid_t = -1
    private var done = false
    private var status: Int32 = 0
    private var stopping = false
    private(set) var cleanupError: Int32? = nil
    var processIdentifier: pid_t { condition.lock(); defer { condition.unlock() }; return pid }
    var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return !done }
    var terminationStatus: Int32 { condition.lock(); defer { condition.unlock() }; return status }
    init(executable: URL, arguments: [String], directory: URL, environment: [String:String], input: Pipe, output: Pipe, errors: Pipe) throws {
        let args = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for p in args + env { if let p { free(p) } } }
        pid = args.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            milk_sandbox_spawn(executable.path, a.baseAddress!, e.baseAddress!, directory.path,
                               input.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor, errors.fileHandleForWriting.fileDescriptor)
        } }
        guard pid > 1 else { throw AgentError.message("Sandbox process could not start (\(errno)). No unrestricted fallback was used.") }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        for fd in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        DispatchQueue.global().async { [self] in
            let leader = processIdentifier
            _ = milk_terminal_wait_exit(leader) // WNOWAIT reserves identity even on ordinary completion.
            signalGroup(SIGTERM); usleep(100_000); signalGroup(SIGKILL)
            var raw: Int32 = 0
            condition.lock()
            if milk_terminal_reap(leader, &raw) < 0 { cleanupError = errno }
            status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : -(raw & 0x7f)
            done = true; pid = -1; condition.broadcast(); condition.unlock()
        }
    }
    private func signalGroup(_ signal: Int32) {
        condition.lock(); defer { condition.unlock() }
        guard !done, pid > 1 else { return }
        if killpg(pid, signal) < 0, errno != ESRCH, errno != EPERM { cleanupError = errno }
        // Darwin may return EPERM for a zombie-only group; never use this as proof
        // of subtree death. The accepted detached-survivor limitation still applies.
    }
    func terminate() {
        condition.lock(); let start = !stopping && !done; stopping = true; condition.unlock()
        guard start else { return }
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in signalGroup(SIGKILL) }
    }
    func waitUntilExit() { condition.lock(); while !done { condition.wait() }; condition.unlock() }
    func read(_ handle: FileHandle) -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var item = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 50)
            if ready > 0 {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count > 0 { return Data(buffer.prefix(count)) }
                if count == 0 { return Data() }
                if errno != EAGAIN && errno != EINTR { return Data() }
            }
            if !isRunning { return Data() } // A detached pipe holder must not hang cleanup.
            if ready < 0 && errno != EINTR { return Data() }
        }
    }
}
