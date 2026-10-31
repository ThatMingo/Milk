import Foundation
import Darwin
import MilkPTY

/// A single Milk-owned controlling PTY session. No Pi transport or approval path.
/// The unreaped session leader pins the SID until all ordinary job-control groups
/// have been signaled. We never discover ownership by command name or cwd.
final class TerminalProcess: @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    var processGroup: pid_t { pid }
    var sessionID: pid_t { pid }
    let workspace: URL?
    let shell: String
    let startupDirectory: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var stopping = false
    private var finished = false
    private var cleanupSucceeded = false
    private var callbacks: [(Bool) -> Void] = []
    private let cleanupDone = DispatchGroup()
    private let readDone = DispatchSemaphore(value: 0)
    private let io: DispatchIO
    private let queue = DispatchQueue(label: "dev.milk.terminal.io", qos: .userInitiated)
    private var onExit: ((Int32, Bool) -> Void)?
    private(set) var lastSize: (cols: Int, rows: Int)

    static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        // Account shell is authoritative for GUI launches; SHELL is a fallback.
        let account = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        for candidate in [account, environment["SHELL"], "/bin/sh"].compactMap({ $0 }) {
            if candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/bin/sh"
    }
    static func environment(shell: String, directory: URL) -> [String: String] {
        var value = ProcessInfo.processInfo.environment
        value["SHELL"] = shell; value["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        value["USER"] = NSUserName(); value["LOGNAME"] = NSUserName()
        value["PWD"] = directory.path; value.removeValue(forKey: "OLDPWD")
        value["TERM"] = "xterm-256color"; value["COLORTERM"] = "truecolor"
        value["TERM_PROGRAM"] = "Milk"; value["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.6.0"
        if value["PATH"]?.isEmpty != false { value["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if value["LANG"] == nil && value["LC_ALL"] == nil { value["LANG"] = "en_US.UTF-8" }
        // No injected project commands, approval variables or input/output logging.
        return value
    }
    init(workspace: URL?, shell: String? = nil, host: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]), cols: Int = 80, rows: Int = 24, output: @escaping (Data) -> Void, onExit: @escaping (Int32, Bool) -> Void) throws {
        self.workspace = workspace
        let directory = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        let executable = shell ?? Self.loginShell()
        startupDirectory = directory
        self.shell = executable
        self.onExit = onExit
        lastSize = (cols, rows)
        let environment = Self.environment(shell: self.shell, directory: startupDirectory)
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in envp { if let pointer { free(pointer) } } }
        var master: Int32 = -1
        let child = envp.withUnsafeBufferPointer { env in
            milk_pty_spawn(host.path, executable, directory.path, UnsafeMutablePointer(mutating: env.baseAddress!), UInt16(clamping: cols), UInt16(clamping: rows), &master)
        }
        guard child > 1 else { throw AgentError.message("Terminal launch failed: \(String(cString: strerror(errno)))") }
        pid = child; descriptor = master
        cleanupDone.enter()
        let ownedDescriptor = master
        io = DispatchIO(type: .stream, fileDescriptor: ownedDescriptor, queue: queue) { _ in close(ownedDescriptor) }
        io.setLimit(lowWater: 1); io.setLimit(highWater: 65_536)
        let readDone = readDone
        io.read(offset: 0, length: Int.max, queue: queue) { done, bytes, error in
            if let bytes, !bytes.isEmpty { output(Data(bytes)) }
            if done { readDone.signal() }
        }
        // Dedicated waiter, rather than tying up a shared dispatch worker for
        // the entire lifetime of an interactive shell.
        let waiter = Thread { [self] in
            let observed = milk_terminal_wait_exit(pid) == 0
            if observed { beginStop() }
            else {
                // Never signal a PID whose child identity can no longer be proved.
                lock.lock(); let shouldRelease = !stopping; stopping = true; lock.unlock()
                if shouldRelease { cleanupDone.leave() }
            }
            cleanupDone.wait()
            var status: Int32 = 0
            let sessionGone = observed && milk_terminal_session_signal(pid, 0) == 0
            let reaped = observed && milk_terminal_reap(pid, &status) == pid
            _ = readDone.wait(timeout: .now() + 0.25)
            lock.lock(); descriptor = -1; lock.unlock()
            io.close(flags: .stop)
            let gone = reaped && sessionGone
            lock.lock(); finished = true; cleanupSucceeded = gone
            let completions = callbacks; callbacks = []
            let exit = self.onExit; self.onExit = nil; lock.unlock()
            DispatchQueue.main.async {
                exit?(status, gone)
                for completion in completions { completion(gone) }
            }
        }
        waiter.name = "Milk Terminal reaper"; waiter.start()
    }
    func send(_ data: Data) {
        lock.lock(); let allowed = !stopping && !finished; lock.unlock()
        guard allowed else { return }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: bytes, queue: queue) { _, _, _ in }
    }
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0, !stopping, !finished else { return }
        if milk_pty_resize(descriptor, UInt16(clamping: cols), UInt16(clamping: rows)) == 0 { lastSize = (cols, rows) }
    }
    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        lock.lock()
        if finished { let gone = cleanupSucceeded; lock.unlock(); DispatchQueue.main.async { completion(gone) }; return }
        callbacks.append(completion); lock.unlock()
        beginStop()
    }
    private func beginStop() {
        lock.lock()
        if stopping { lock.unlock(); return }
        stopping = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Session membership includes foreground/background job groups, unlike
            // kill(-shellPID), which misses interactive shell job control.
            _ = milk_terminal_session_signal(pid, SIGHUP)
            _ = milk_terminal_session_signal(pid, SIGCONT)
            _ = milk_terminal_session_signal(pid, SIGTERM)
            for _ in 0..<25 {
                if milk_terminal_session_signal(pid, 0) == 0 { break }
                usleep(40_000)
            }
            _ = milk_terminal_session_signal(pid, SIGKILL)
            for _ in 0..<25 {
                if milk_terminal_session_signal(pid, 0) == 0 { break }
                usleep(20_000)
            }
            cleanupDone.leave()
        }
    }
}
