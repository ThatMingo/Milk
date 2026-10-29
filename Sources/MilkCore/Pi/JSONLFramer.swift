import Foundation

public struct JSONLFramer: Sendable {
    private var pending = Data()
    public var maximumFrameBytes: Int
    public init(maximumFrameBytes: Int = 128 * 1024 * 1024) { self.maximumFrameBytes = maximumFrameBytes }
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        pending.append(data); var records: [JSONValue] = []
        while let newline = pending.firstIndex(of: 10) {
            var frame = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if frame.last == 13 { frame.removeLast() }
            guard frame.count <= maximumFrameBytes else { throw MilkError.message("Pi protocol frame exceeds limit") }
            if frame.isEmpty { continue }
            do { records.append(try JSONDecoder().decode(JSONValue.self, from: frame)) }
            catch { throw MilkError.message("Malformed Pi JSONL record") }
        }
        guard pending.count <= maximumFrameBytes else { throw MilkError.message("Pi protocol frame exceeds limit") }
        return records
    }
    public func finish() throws {
        if !pending.isEmpty { throw MilkError.message("Pi exited with an incomplete protocol frame") }
    }
}
