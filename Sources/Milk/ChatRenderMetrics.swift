import Foundation

/// Opt-in diagnostic collection. No retained samples or clock reads in normal use.
final class ChatRenderMetrics: @unchecked Sendable {
    static let shared = ChatRenderMetrics()
    static let enabled = CommandLine.arguments.contains("--verify-chat-quality")
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]
    private var units: [String: Int] = [:]
    static func begin() -> UInt64? { enabled ? DispatchTime.now().uptimeNanoseconds : nil }
    static func end(_ name: String, _ start: UInt64?, units: @autoclosure () -> Int = 0) {
        guard let start else { return }
        shared.record(name, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, units: units())
    }
    func record(_ name: String, milliseconds: Double, units count: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        if samples[name, default: []].count < 30_000 { samples[name, default: []].append(milliseconds) }
        units[name, default: 0] += count
    }
    func reset() { lock.lock(); defer { lock.unlock() }; samples = [:]; units = [:] }
    func snapshot() -> [String: [String: Double]] {
        lock.lock(); defer { lock.unlock() }
        return samples.mapValues { values in
            let ordered = values.sorted(), count = ordered.count
            return ["count": Double(count), "total_ms": values.reduce(0, +), "mean_ms": values.reduce(0, +) / Double(max(1, count)),
                    "p95_ms": ordered.isEmpty ? 0 : ordered[min(count - 1, Int(Double(count - 1) * 0.95))], "max_ms": ordered.last ?? 0]
        }
    }
}
