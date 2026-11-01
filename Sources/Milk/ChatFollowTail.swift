import Foundation

struct ChatScrollMetrics: Equatable {
    var offset: Double
    var contentHeight: Double
    var viewportHeight: Double
    var distanceFromBottom: Double { max(0, contentHeight - viewportHeight - offset) }
    var nearBottom: Bool { distanceFromBottom <= ChatFollowTailState.enterDistance }
}

/// Layout growth is not evidence of user intent. Only user scrolling can leave
/// the tail; downward scrolling back near it resumes native size-change anchoring.
struct ChatFollowTailState {
    static let enterDistance = 24.0
    static let exitDistance = 48.0
    var followsTail = true
    var userScrolling = false
    private var previous: ChatScrollMetrics?
    private var upwardTravel = 0.0
    mutating func update(_ metrics: ChatScrollMetrics) {
        defer { previous = metrics }
        guard userScrolling, let previous else { return }
        let movement = metrics.offset - previous.offset
        let maximumOffset = max(0, metrics.contentHeight - metrics.viewportHeight)
        let clampedToBottom = previous.offset > maximumOffset + 0.5 && abs(metrics.offset - maximumOffset) < 0.5
        // Growth and a wheel event may land in one layout pass. Do not discard
        // downward return-to-tail intent just because content also grew.
        // Shrinking/resizing alone can clamp offsets upward, so exclude that.
        if movement < -0.5 && !clampedToBottom && metrics.contentHeight >= previous.contentHeight && metrics.viewportHeight == previous.viewportHeight {
            upwardTravel += -movement
            if upwardTravel >= Self.exitDistance && metrics.distanceFromBottom >= Self.exitDistance { followsTail = false }
        } else if movement > 0.5 {
            upwardTravel = 0
            if metrics.nearBottom { followsTail = true }
        }
    }
}

/// Geometry bookkeeping does not publish observable application state per pixel.
final class ChatScrollMemory {
    var follow = ChatFollowTailState()
    var offset: Double?
    private var visible: [String: ChatReadingAnchor] = [:]
    var pendingResizeAnchor: ChatReadingAnchor?
    var settledReadingAnchor: ChatReadingAnchor?
    private(set) var userScrollGeneration = 0
    func beginUserScroll() {
        if !follow.userScrolling { userScrollGeneration += 1 }
        follow.userScrolling = true
        pendingResizeAnchor = nil
    }
    var readingAnchor: ChatReadingAnchor? {
        pendingResizeAnchor ?? visibleAnchor
    }
    var visibleAnchor: ChatReadingAnchor? { visible.values.min { $0.order.lexicographicallyPrecedes($1.order) } }
    func setVisible(_ anchor: ChatReadingAnchor, visible isVisible: Bool) {
        if isVisible { visible[anchor.id] = anchor } else { visible[anchor.id] = nil }
    }
    func removeVisible(_ id: String) { visible[id] = nil }
    func isVisible(_ id: String) -> Bool { visible[id] != nil }
    var visibleIDs: [String] { visible.keys.sorted() }
}

/// Explicit verification mode only; no retained view closures in normal use.
@MainActor enum ChatScrollAudit {
    static var owner: String?
    static var snapshot: (() -> [String: Any])?
}
