import Foundation

/// Who owns the transcript scrollbar's visibility.
///
/// AppKit's overlay scroller is revealed whenever the clip view moves, and it is not
/// reliably faded again when the movement came from a layout commit. A streaming
/// transcript commits geometry on every flush, so left to AppKit the bar stays up for
/// the whole answer. Milk reveals it for a genuine reader gesture (wheel, knob drag,
/// keyboard) and fades it once the reader goes idle.
struct ChatScrollerVisibility {
    /// How long a gesture keeps the bar available, so a reader can grab the knob
    /// mid-gesture without hunting for it.
    static let visibleFor: TimeInterval = 1.4
    static let revealDuration: TimeInterval = 0.18
    static let fadeDuration: TimeInterval = 0.35

    private(set) var revealedUntil = Date.distantPast

    mutating func noteGesture(at now: Date = Date()) {
        revealedUntil = now.addingTimeInterval(Self.visibleFor)
    }

    func isRevealed(at now: Date = Date()) -> Bool { now < revealedUntil }

    /// When the current gesture should give the bar back to hiding.
    var fadeDelay: TimeInterval { max(0, revealedUntil.timeIntervalSinceNow) }
}
