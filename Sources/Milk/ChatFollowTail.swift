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
    /// Live resize notifications change the viewport by sub-pixel amounts on every
    /// frame. Strict Double equality made a wheel gesture that overlapped a sidebar
    /// or divider animation unrecordable, so genuine upward travel was silently
    /// discarded while the pane moved.
    static let viewportTolerance = 1.0
    var followsTail = true
    var userScrolling = false
    private var previous: ChatScrollMetrics?
    private var upwardTravel = 0.0
    /// Upward distance the reader themselves asked for, from genuine wheel or key
    /// events. Observed movement alone cannot tell a gesture apart from a tail pin
    /// putting the reader back at the bottom, and a tail pin moves the offset without
    /// the reader, so measuring intent by position makes the two fight each other.
    private var requestedUpward = 0.0
    /// The reader asked to move up and has not withdrawn that by coming back down.
    var hasPendingUpwardRequest: Bool { requestedUpward > 0 }

    /// Signed upward distance a real user event requested, clamped to the room the
    /// document actually had above the current offset. Downward travel gives the
    /// request back.
    mutating func noteRequest(up: Double, room: Double) {
        guard up > 0 else {
            requestedUpward = max(0, requestedUpward - min(-up, max(0, requestedUpward)))
            return
        }
        requestedUpward += min(up, max(0, room))
        // Enough deliberate upward distance is reading, not jitter: stop pulling the
        // reader back to the tail.
        guard followsTail, requestedUpward >= Self.exitDistance else { return }
        followsTail = false
        requestedUpward = 0
        upwardTravel = 0
    }

    mutating func update(_ metrics: ChatScrollMetrics) {
        defer { previous = metrics }
        guard userScrolling, let previous else { return }
        let movement = metrics.offset - previous.offset
        let maximumOffset = max(0, metrics.contentHeight - metrics.viewportHeight)
        let clampedToBottom = previous.offset > maximumOffset + 0.5 && abs(metrics.offset - maximumOffset) < 0.5
        // Growth and a wheel event may land in one layout pass. Do not discard
        // downward return-to-tail intent just because content also grew.
        // Shrinking/resizing alone can clamp offsets upward, so exclude that.
        if movement < -0.5 && !clampedToBottom && metrics.contentHeight >= previous.contentHeight
            && abs(metrics.viewportHeight - previous.viewportHeight) <= Self.viewportTolerance {
            upwardTravel += -movement
            if upwardTravel >= Self.exitDistance {
                followsTail = false
                requestedUpward = 0
            }
        } else if movement > 0.5 {
            upwardTravel = 0
            requestedUpward = 0
            if metrics.nearBottom { followsTail = true }
        }
    }

    /// An offset a layout commit chose is not reader movement. Re-baseline so the next
    /// observation measures the reader rather than the commit that moved them.
    mutating func rebaseline(_ metrics: ChatScrollMetrics) { previous = metrics }
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
    /// Toggles a transcript disclosure the way a click does, returning the row owner.
    static var disclose: ((String) -> String)?
}
