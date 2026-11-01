import Foundation

/// Exact document geometry. Scrolling only queries this index; it never measures
/// a view, changes a cached height, or asks a lazy stack to estimate the extent.
struct ChatTranscriptLayout {
    struct Row: Equatable {
        var id: String
        var owner: String
        var height: Double
        var gap: Double
    }
    private(set) var rows: [Row] = []
    private(set) var origins: [Double] = []
    private(set) var height = 45.0
    private var indices: [String: Int] = [:]
    mutating func replace(_ rows: [Row]) {
        self.rows = rows
        origins.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        var y = 28.0
        for (i, row) in rows.enumerated() {
            y += i == 0 ? 0 : row.gap
            origins.append(y); indices[row.id] = i
            y += max(1, row.height)
        }
        height = y + (rows.isEmpty ? 17 : 22 + 17)
    }
    func index(at offset: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0, high = origins.count
        while low < high {
            let middle = (low + high) / 2
            if origins[middle] + rows[middle].height < offset { low = middle + 1 } else { high = middle }
        }
        return min(low, rows.count - 1)
    }
    func range(offset: Double, viewport: Double, overscan: Double = 0) -> Range<Int> {
        guard let start = index(at: max(0, offset - overscan)), let end = index(at: offset + viewport + overscan) else { return 0..<0 }
        return start..<min(rows.count, end + 1)
    }
    func anchor(offset: Double) -> (id: String, fraction: Double)? {
        guard let i = index(at: offset) else { return nil }
        return (rows[i].id, min(1, max(0, (offset - origins[i]) / max(1, rows[i].height))))
    }
    func offset(id: String, fraction: Double = 0) -> Double? {
        guard let i = indices[id] else { return nil }
        return origins[i] + rows[i].height * fraction
    }
}
