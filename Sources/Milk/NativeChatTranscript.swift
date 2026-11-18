import AppKit
import SwiftUI

/// A real AppKit scroll document with exact, retained row geometry. Only visible
/// pieces and one viewport of overscan have hosting views. A small measurement
/// pool reuses one host per visual kind, never one hidden text view per row.
struct NativeChatTranscript: NSViewRepresentable {
    let rows: [ChatTranscriptRow]
    let session: ChatTranscriptSession
    let conversation: SessionConversation
    let narrow: Bool
    let sessionID: Int
    let paneWidth: Double
    let remember: (Double, ChatReadingAnchor?, Bool, Double) -> Void
    let content: (ChatTranscriptRow) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        let scroller = TranscriptScroller()
        scroller.scrollerStyle = .overlay
        scroller.input = { [weak coordinator = context.coordinator] active in coordinator?.input(active) }
        scroll.verticalScroller = scroller
        scroll.scrollerStyle = .overlay
        scroller.setMilkHidden(true)   // shown by a reader gesture, hidden again when idle
        scroll.identifier = .init("milk.chat.transcript")
        scroll.setAccessibilityIdentifier("milk.chat.transcript")
        scroll.documentView = context.coordinator.document
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        scroll.changed = { [weak coordinator = context.coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator = context.coordinator] active in coordinator?.input(active) }
        scroll.travel = { [weak coordinator = context.coordinator] up in coordinator?.travel(up) }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        return scroll
    }
    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        let environment = context.environment
        if context.coordinator.colorScheme != environment.colorScheme || context.coordinator.enabled != environment.isEnabled {
            context.coordinator.colorScheme = environment.colorScheme
            context.coordinator.enabled = environment.isEnabled
            context.coordinator.refreshEnvironment = true
        }
        context.coordinator.update(self, root: { row in
            AnyView(content(row).frame(maxWidth: .infinity, alignment: .leading).font(.system(size: 13)).foregroundStyle(MilkTheme.ink)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.isEnabled, environment.isEnabled)
                .environment(\.milkExtensionRegistry, environment.milkExtensionRegistry)
                .environment(\.milkExtensionActionContext, environment.milkExtensionActionContext))
        })
    }
    static func dismantleNSView(_ scroll: TranscriptScrollView, coordinator: Coordinator) {
        coordinator.persist()
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        if ChatScrollAudit.owner == coordinator.identity { ChatScrollAudit.snapshot = nil; ChatScrollAudit.disclose = nil; ChatScrollAudit.owner = nil }
        scroll.changed = nil; scroll.input = nil; scroll.travel = nil
    }

    @MainActor final class Coordinator {
        static let reflowDebounce: TimeInterval = 0.08
        let identity = UUID().uuidString
        let document = TranscriptDocument()
        weak var scroll: TranscriptScrollView?
        var observer: NSObjectProtocol?
        var parent: NativeChatTranscript?
        var root: ((ChatTranscriptRow) -> AnyView)?
        var layout = ChatTranscriptLayout()
        var hosts: [String: NSHostingView<AnyView>] = [:]
        var hostedContent: [String: ChatTranscriptRow.Content] = [:]
        var measuring: [Int: NSHostingController<AnyView>] = [:]
        var follow = ChatFollowTailState()
        var visibility = ChatScrollerVisibility()
        var colorScheme: ColorScheme?
        var enabled = true
        var refreshEnvironment = false
        var width = 0.0
        var viewport = 0.0
        var updating = false
        var initialized = false
        var pendingPersist: DispatchWorkItem?
        var pendingInput: DispatchWorkItem?
        var pendingReflow: DispatchWorkItem?
        var committingReflow = false
        /// How long a reader's own upward travel keeps a layout commit from pinning the
        /// tail. Long enough to cover a run of wheel notches, short enough that a small
        /// jog the reader abandoned does not silently stop following forever.
        static let travelHoldWindow: TimeInterval = 0.6
        var travelDeadline = Date.distantPast
        /// The content width the retained row measurements belong to. During a live
        /// drag this deliberately lags `width` so a piece is never handed a width its
        /// measured height no longer fits.
        var activeContentWidth = 0.0
        var forceLayout = false
        var lastRows: [ChatTranscriptRow] = []
        var lastDisclosureRevision = 0
        var measuredCount = 0
        init() {
            document.keyboardScroll = { [weak self] delta, end in self?.keyboard(delta: delta, end: end) }
        }
        func update(_ parent: NativeChatTranscript, root: @escaping (ChatTranscriptRow) -> AnyView) {
            self.parent = parent; self.root = root
            guard let scroll else { return }
            if !initialized { follow.followsTail = parent.conversation.followsTail; lastDisclosureRevision = parent.session.disclosureRevision }
            let newWidth = max(1, scroll.contentView.bounds.width)
            guard newWidth > 1 else { return }
            // The representable can receive a provisional frame before SwiftUI
            // installs the pane's actual width. Do not consume a saved reading
            // offset as a different-width restore during that handoff.
            guard initialized || abs(newWidth - parent.paneWidth) < 1 else { return }
            let reflow = abs(width - newWidth) > 0.5
            // A live drag hands the transcript a new bounds width on every frame, and a
            // long transcript would remeasure every piece for every one of them. Only a
            // frame whose content also changed has to be relaid out, and while the drag
            // is in flight the pieces keep the width they were measured at: handing a
            // piece a new width while keeping its old height hides its own text.
            if initialized && reflow && !committingReflow { armReflowCommit(Self.reflowDebounce) }
            // A commit is outstanding, so the pieces on screen keep the width their
            // retained heights were measured at until that commit runs.
            let retainingWidth = pendingReflow != nil && activeContentWidth > 1
            let forced = forceLayout
            forceLayout = false
            let changed = lastRows != parent.rows || refreshEnvironment || forced
            let resized = viewport != scroll.contentView.bounds.height
            guard changed || reflow || resized || !initialized else { return }
            // A disclosure toggle re-measures pieces without appending stream content,
            // so it must not be treated as the tail moving.
            let disclosure = parent.session.disclosureRevision != lastDisclosureRevision
            lastDisclosureRevision = parent.session.disclosureRevision
            let metric = ChatRenderMetrics.begin()
            defer { ChatRenderMetrics.end("document.layout", metric) }
            let oldOffset = scroll.contentView.bounds.minY
            let anchor = layout.anchor(offset: oldOffset)
            let anchorDelta = anchor.flatMap { layout.offset(id: $0.id) }.map { oldOffset - $0 } ?? 0
            let oldRows = Dictionary(lastRows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            updating = true
            width = newWidth
            viewport = scroll.contentView.bounds.height
            let contentWidth = retainingWidth && activeContentWidth > 1
                ? activeContentWidth
                : max(1, min(720, width - (parent.narrow ? 40 : 64)))
            activeContentWidth = contentWidth
            var geometry: [ChatTranscriptLayout.Row] = []
            measuredCount = 0
            for row in parent.rows {
                let h: Double
                if let cached = parent.session.heights[row.id], cached.0 == row.content, cached.1 == contentWidth { h = cached.2 }
                else if case .markdown(let block, let live) = row.content, !live, let cached = parent.session.markdownHeights.height(at: contentWidth, for: block) { h = cached }
                else {
                    let key = measurementKind(row.content)
                    let host: NSHostingController<AnyView>
                    if let reused = measuring[key] { host = reused }
                    else { host = NSHostingController(rootView: AnyView(EmptyView())); host.sizingOptions = []; measuring[key] = host }
                    h = autoreleasepool {
                        host.rootView = root(row)
                        return max(1, host.sizeThatFits(in: .init(width: contentWidth, height: .greatestFiniteMagnitude)).height)
                    }
                    measuredCount += 1
                    // A streaming piece is measured again on the next delta, so its
                    // key is never retained here; only settled pieces are shared.
                    if case .markdown(let block, let live) = row.content, !live {
                        parent.session.markdownHeights.setHeight(h, at: contentWidth, for: block)
                    }
                }
                parent.session.heights[row.id] = (row.content, contentWidth, h)
                geometry.append(.init(id: row.id, owner: row.owner, height: h, gap: row.gap))
                if let host = hosts[row.id], reflow || refreshEnvironment || oldRows[row.id]?.content != row.content { host.rootView = root(row); hostedContent[row.id] = row.content }
            }
            let liveIDs = Set(parent.rows.map(\.id))
            parent.session.heights = parent.session.heights.filter { liveIDs.contains($0.key) }
            for host in measuring.values { host.rootView = AnyView(EmptyView()) }
            layout.replace(geometry)
            lastRows = parent.rows
            document.frame = .init(x: 0, y: 0, width: width, height: max(layout.height, scroll.contentView.bounds.height))
            let target: Double
            // A pin is the transcript choosing the bottom. While the reader has an
            // unanswered upward request that is exactly the thing they are fighting,
            // so their own position is kept instead.
            if follow.followsTail && !disclosure && !readerHoldsPosition { target = maximumOffset }
            else if initialized, let anchor, let restored = layout.offset(id: anchor.id, fraction: reflow ? anchor.fraction : 0) { target = restored + (reflow ? 0 : anchorDelta) }
            else if let id = parent.conversation.scrollAnchor, let savedWidth = parent.conversation.scrollWidth, abs(savedWidth - width) > 1, contentWidth < 720,
                    let restored = layout.offset(id: id) { target = restored }
            else { target = parent.conversation.scrollOffset ?? 0 }
            scroll.contentView.scroll(to: .init(x: 0, y: min(maximumOffset, max(0, target))))
            scroll.reflectScrolledClipView(scroll.contentView)
            initialized = true
            refreshEnvironment = false
            // Geometry replacement is layout, never user intent.
            follow.rebaseline(metrics)
            if disclosure {
                // Opening a disclosure is the reader asking to look at something, so the
                // position they were at is kept. The tail is re-adopted only when that
                // kept position genuinely is the bottom, as it is after a collapse.
                follow.followsTail = metrics.nearBottom
            }
            materialize()
            updating = false
            installAudit()
            schedulePersist()
            // Commits are not gestures: streamed output must not keep the bar revealed.
            fadeScrollerIfIdle()
        }
        private func measurementKind(_ content: ChatTranscriptRow.Content) -> Int {
            switch content {
            case .user: return 0
            case .header: return 1
            case .thinking: return 2
            case .activity: return 3
            case .changes: return 4
            case .notice: return 5
            case .error: return 6
            case .empty: return 7
            case .markdown(let block, _):
                switch block {
                case .paragraph: return 8
                case .heading: return 9
                case .code: return 10
                case .quote: return 11
                case .list: return 12
                case .rule: return 13
                }
            }
        }
        var maximumOffset: Double { max(0, (scroll?.documentView?.frame.height ?? 0) - (scroll?.contentView.bounds.height ?? 0)) }
        var metrics: ChatScrollMetrics {
            .init(offset: Double(scroll?.contentView.bounds.minY ?? 0), contentHeight: Double(scroll?.documentView?.frame.height ?? 0), viewportHeight: Double(scroll?.contentView.bounds.height ?? 0))
        }
        func materialize() {
            let metric = ChatRenderMetrics.begin()
            defer { ChatRenderMetrics.end("document.materialize", metric) }
            guard let scroll, let parent, let root else { return }
            let bounds = scroll.contentView.bounds
            let range = layout.range(offset: bounds.minY, viewport: bounds.height, overscan: max(600, bounds.height))
            var wanted = Set(range.map { lastRows[$0].id })
            // Keep the focused/selecting text view alive until focus moves away.
            if let responder = scroll.window?.firstResponder as? NSView {
                for (id, host) in hosts where layout.offset(id: id) != nil && responder.isDescendant(of: host) { wanted.insert(id) }
            }
            for id in Array(hosts.keys) where !wanted.contains(id) {
                hosts.removeValue(forKey: id)?.removeFromSuperview(); hostedContent[id] = nil
            }
            let contentWidth = activeContentWidth > 1
                ? activeContentWidth
                : max(1, min(720, width - (parent.narrow ? 40 : 64)))
            let x = (width - contentWidth) / 2
            var added = false
            for i in range {
                let row = lastRows[i]
                let host: NSHostingView<AnyView>
                if let existing = hosts[row.id] { host = existing }
                else {
                    host = NSHostingView(rootView: root(row)); host.sizingOptions = []
                    host.safeAreaRegions = []
                    hosts[row.id] = host; hostedContent[row.id] = row.content
                    document.addSubview(host); added = true
                }
                host.frame = .init(x: x, y: layout.origins[i], width: contentWidth, height: layout.rows[i].height)
            }
            // A focused offscreen piece may be pinned for native selection.
            // Reflow it too, and never keep a piece removed by a history snapshot.
            for (id, host) in hosts {
                if let y = layout.offset(id: id), let height = parent.session.heights[id]?.2 {
                    host.frame = .init(x: x, y: y, width: contentWidth, height: height)
                }
            }
            if added {
                document.sortSubviews({ a, b, _ in
                    a.frame.minY < b.frame.minY ? .orderedAscending : .orderedDescending
                }, context: nil)
            }
            if ChatRenderMetrics.enabled, !lastRows.isEmpty, bounds.height > 50 {
                let visible = hosts.values.contains { $0.superview === document && $0.frame.intersects(bounds) }
                if !visible { ChatRenderMetrics.shared.record("document.blank", milliseconds: 0) }
                assert(visible, "Nonempty transcript has no mounted view intersecting the viewport")
            }
        }
        /// Verification only. Structural evidence for the two ways a transcript can look
        /// empty even though its document geometry is exact: a piece the layout places in
        /// the viewport that is not mounted, and native text that no longer fits the frame
        /// its measured height assigned. Neither is visible from document size alone.
        func visibleCoverageAudit() -> [String: Double] {
            guard let scroll else { return [:] }
            let bounds = scroll.contentView.bounds
            guard bounds.height > 50 else { return [:] }
            var hole = 0.0, holeRow = ""
            for index in layout.range(offset: bounds.minY, viewport: bounds.height) {
                let row = layout.rows[index]
                if hosts[row.id]?.superview === document { continue }
                let low = max(bounds.minY, layout.origins[index])
                let high = min(bounds.maxY, layout.origins[index] + row.height)
                if high - low > hole { hole = high - low; holeRow = row.id }
            }
            var clip = 0.0, clippedRow = "", blank = 0.0, blankRow = ""
            var clipText = 0.0, clipFrame = 0.0, clipHostWidth = 0.0
            for (id, host) in hosts where host.frame.intersects(bounds) {
                host.layoutSubtreeIfNeeded()
                for view in Self.nativeSubviews(of: host) {
                    guard let text = view as? NSTextView, let container = text.textContainer, let manager = text.layoutManager else { continue }
                    manager.ensureLayout(for: container)
                    // A trailing newline reserves an empty final line that paints nothing,
                    // so it is not part of the visible extent (measurement ignores it too).
                    var laid = Double(manager.usedRect(for: container).height)
                    if text.string.hasSuffix("\n") { laid -= Double(manager.extraLineFragmentRect.height) }
                    // NSTextView is flipped, so laid-out text ends this far below its top.
                    let end = document.convert(NSPoint(x: 0, y: laid), from: view)
                    if end.y - host.frame.maxY > clip {
                        clip = end.y - host.frame.maxY; clippedRow = id
                        clipText = laid; clipFrame = host.frame.height; clipHostWidth = host.frame.width
                    }
                    if host.frame.maxY - end.y > blank { blank = host.frame.maxY - end.y; blankRow = id }
                }
            }
            if ChatRenderMetrics.enabled {
                // Inter-row spacing is at most 22pt, so a larger band is a hole the reader
                // actually sees. Channels are asserted by scripts/verify-chat-geometry.py.
                if hole > 40 { ChatRenderMetrics.shared.record("document.blank.band", milliseconds: hole) }
                if clip > 1 { ChatRenderMetrics.shared.record("document.text.clipped", milliseconds: clip) }
                if blank > 40 { ChatRenderMetrics.shared.record("document.text.blank", milliseconds: blank) }
            }
            lastAuditRowIDs = ["unmountedRow": holeRow, "clippedRow": clippedRow, "blankRow": blankRow]
            return ["unmountedGap": hole, "unmountedRow": Double(holeRow.utf8.count),
                    "clippedPoints": max(0, clip),
                    "clippedRow": Double(clippedRow.utf8.count),
                    "clippedTextHeight": clipText, "clippedFrameHeight": clipFrame, "clippedHostWidth": clipHostWidth,
                    "trailingBlank": max(0, blank), "blankRow": Double(blankRow.utf8.count),
                    "viewport": Double(bounds.height), "mounted": Double(hosts.count)]
        }
        /// Verification only: the row identifiers behind the worst hole, clip and
        /// blank band found by the last `visibleCoverageAudit()`, so a failing run
        /// names the piece instead of guessing from its id length.
        private(set) var lastAuditRowIDs: [String: String] = [:]

        private static func nativeSubviews(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + nativeSubviews(of: $0) }
        }
        func scrolled() {
            guard !updating else { return }
            guard let scroll else { return }
            // Width/height changes come from the native clip view, including
            // sidebar and pane animation; they are not wheel intent.
            if (!initialized || abs(width - scroll.contentView.bounds.width) > 0.5 || viewport != scroll.contentView.bounds.height), let parent, let root { update(parent, root: root); return }
            follow.update(metrics)
            materialize()
            schedulePersist()
        }
        /// A genuine reader gesture: reveal the scrollbar and leave it grabbable for a
        /// moment so the knob can actually be grabbed.
        func readerGesture() {
            visibility.noteGesture()
            (scroll?.verticalScroller as? TranscriptScroller)?.revealByReader()
        }
        /// Layout commits, streamed output and pane resizing are not gestures. They may
        /// move the clip view, but they do not earn the scrollbar.
        func fadeScrollerIfIdle() {
            guard !visibility.isRevealed() else { return }
            (scroll?.verticalScroller as? TranscriptScroller)?.fadeNow()
        }
        /// Signed upward distance a genuine wheel or key event asked for, before any
        /// clamp. This is the only evidence of intent a tail pin cannot manufacture.
        func travel(_ upward: Double) {
            follow.noteRequest(up: upward, room: metrics.offset)
            travelDeadline = Date().addingTimeInterval(Self.travelHoldWindow)
        }
        /// The reader asked to move up and is still asking. A commit may not answer by
        /// putting them back at the bottom.
        var readerHoldsPosition: Bool { follow.hasPendingUpwardRequest && Date() <= travelDeadline }
        func input(_ active: Bool) {
            pendingInput?.cancel()
            if active { follow.userScrolling = true; readerGesture() }
            else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.follow.update(self.metrics); self.follow.userScrolling = false; self.persist()
                }
                pendingInput = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                (scroll?.verticalScroller as? TranscriptScroller)?.fadeWhenIdle(after: visibility.fadeDelay)
            }
        }
        private func armReflowCommit(_ delay: TimeInterval) {
            pendingReflow?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.commitReflow() }
            pendingReflow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        /// The pane stopped moving: measure at the width the transcript now has.
        private func commitReflow() {
            pendingReflow = nil
            guard let latest = parent, let root, let scroll else { return }
            forceLayout = true
            committingReflow = true
            update(latest, root: root)
            committingReflow = false
            // The pane kept moving while this layout was being measured. A long drag then
            // reflows at this interval instead of remeasuring every piece every frame.
            if abs(scroll.contentView.bounds.width - width) > 0.5 { armReflowCommit(Self.reflowDebounce * 4) }
        }

        func keyboard(delta: Double, end: Bool?) {
            guard let scroll else { return }
            input(true)
            // Home and Page Up ask to leave the tail, End asks to come back to it.
            travel(end.map { $0 ? -metrics.offset : metrics.offset } ?? -delta)
            let y = end.map { $0 ? maximumOffset : 0 } ?? (metrics.offset + delta)
            scroll.contentView.scroll(to: .init(x: 0, y: max(0, min(maximumOffset, y))))
            scroll.reflectScrolledClipView(scroll.contentView); scrolled(); input(false)
        }
        func schedulePersist() {
            pendingPersist?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persist() }
            pendingPersist = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        func persist() {
            guard initialized, let parent else { return }
            let i = layout.index(at: metrics.offset)
            let anchor = i.map { ChatReadingAnchor(id: lastRows[$0].id, ownerID: lastRows[$0].owner, order: lastRows[$0].order) }
            parent.remember(metrics.offset, anchor, follow.followsTail, width)
        }
        /// Thinking disclosures the reader can actually see, in reading order. Verification
        /// uses these keys so an expand/collapse targets a piece that is really mounted
        /// rather than depending on where a generated response happens to end.
        private func visibleThinkingOwners(visible: [Int]) -> [String] {
            guard let scroll else { return [] }
            var keys: [String] = []
            for index in visible {
                let row = lastRows[index]
                guard case .thinking = row.content, hosts[row.id]?.frame.intersects(scroll.contentView.bounds) == true else { continue }
                if !keys.contains(row.owner) { keys.append(row.owner) }
            }
            return keys
        }
        /// The thinking disclosure the reader can actually see, i.e. what a click hits.
        private var visibleThinkingOwner: String? {
            visibleThinkingOwners(visible: auditVisible()).first
        }
        private func auditVisible() -> [Int] {
            guard let scroll else { return [] }
            return layout.range(offset: metrics.offset, viewport: metrics.viewportHeight).filter { index in
                guard let host = hosts[lastRows[index].id] else { return false }
                return host.superview === document && host.frame.intersects(scroll.contentView.bounds)
            }
        }
        func installAudit() {
            guard ChatRenderMetrics.enabled else { return }
            ChatScrollAudit.owner = identity
            ChatScrollAudit.snapshot = { [weak self] in
                guard let self, let parent = self.parent else { return [:] }
                let range = self.layout.range(offset: self.metrics.offset, viewport: self.metrics.viewportHeight)
                let visible = range.filter { index in
                    guard let host = self.hosts[self.lastRows[index].id] else { return false }
                    return host.superview === self.document && host.frame.intersects(self.scroll?.contentView.bounds ?? .zero)
                }
                return ["session": parent.sessionID, "viewIdentity": self.identity, "position": "native exact document", "localFollow": self.follow.followsTail,
                        "userScrolling": self.follow.userScrolling, "visibleIDs": visible.map { self.lastRows[$0].id },
                        "thinkingKeys": self.visibleThinkingOwners(visible: visible),
                        "rendered": self.visibleCoverageAudit(), "renderedRows": self.lastAuditRowIDs,
                        "readingTarget": visible.first.map { self.lastRows[$0].id } ?? "",
                        "markdownCacheEntries": parent.session.cacheEntries, "markdownCacheBytes": parent.session.markdownHeights.retainedBytes,
                        "projectionBytes": parent.session.projection.retainedBytes, "disclosureRevision": parent.session.disclosureRevision,
                        "projectedItems": parent.session.projection.items(messages: parent.conversation.messages, activities: parent.conversation.activities).count,
                        "logicalRows": self.lastRows.count, "materialized": self.hosts.count, "visibleRange": [range.lowerBound, range.upperBound],
                        "materializedRange": [self.layout.range(offset: self.metrics.offset, viewport: self.metrics.viewportHeight, overscan: max(600, self.metrics.viewportHeight)).lowerBound, self.layout.range(offset: self.metrics.offset, viewport: self.metrics.viewportHeight, overscan: max(600, self.metrics.viewportHeight)).upperBound],
                        "measuredThisLayout": self.measuredCount, "heightCacheCount": parent.session.heights.count, "measurementHosts": self.measuring.count]
            }
            ChatScrollAudit.disclose = { [weak self] key in
                guard let self, let parent = self.parent, let root = self.root else { return "" }
                let target = key.isEmpty ? (self.visibleThinkingOwner ?? "") : key
                guard !target.isEmpty else { return "" }
                parent.session.choices[target] = !(parent.session.choices[target] ?? false)
                self.update(parent, root: root)
                return target
            }
        }
    }
}

final class TranscriptDocument: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var keyboardScroll: ((Double, Bool?) -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: keyboardScroll?(-40, nil)
        case 125: keyboardScroll?(40, nil)
        case 116: keyboardScroll?(-(enclosingScrollView?.contentView.bounds.height ?? 400) * 0.9, nil)
        case 121, 49: keyboardScroll?((enclosingScrollView?.contentView.bounds.height ?? 400) * 0.9, nil)
        case 115: keyboardScroll?(0, false)
        case 119: keyboardScroll?(0, true)
        default: super.keyDown(with: event)
        }
    }
}
final class TranscriptScrollView: NSScrollView {
    var changed: (() -> Void)?
    var input: ((Bool) -> Void)?
    /// Signed upward distance the reader asked for, reported before the clamp so the
    /// coordinator can tell a gesture apart from its own tail pin.
    var travel: ((Double) -> Void)?
    override func layout() { super.layout(); changed?() }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0 else { super.scrollWheel(with: event); return }
        input?(true)
        // Vertical gestures belong to the transcript document, even above a
        // nested horizontal code scroller. Native wheel deltas already include
        // the system's direction/acceleration and momentum events.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : verticalLineScroll
        // The clip view moves by -delta, so a positive native delta is upward distance.
        travel?(event.scrollingDeltaY * scale)
        let maximum = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        let y = max(0, min(maximum, contentView.bounds.minY - event.scrollingDeltaY * scale))
        contentView.scroll(to: .init(x: 0, y: y))
        reflectScrolledClipView(contentView); changed?(); input?(false)
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        changed?()
    }
}

final class TranscriptScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var input: ((Bool) -> Void)?
    private var fadeWork: DispatchWorkItem?
    private var generation = 0
    /// NSScrollView.tile calls _setVerticalScrollerHidden: whenever the clip view moves,
    /// including Milk's own tail pins and layout commits, and reverts the bar to visible.
    /// That write path is ordinary isHidden assignment, so it is blocked here: only Milk
    /// changes visibility, through setMilkHidden. Without the guard the bar is revealed
    /// by every streaming commit and (via AppKit's autohide bookkeeping) stays up.
    private var visibilityOwnedByMilk = true

    override var isHidden: Bool {
        get { super.isHidden }
        set { guard visibilityOwnedByMilk else { super.isHidden = newValue; return } }
    }

    /// The one path that may move the scroller's hidden state.
    func setMilkHidden(_ hidden: Bool) {
        visibilityOwnedByMilk = false
        defer { visibilityOwnedByMilk = true }
        super.isHidden = hidden
    }

    /// The reader moved: make the bar available. A layout commit never calls this.
    func revealByReader() {
        generation += 1
        fadeWork?.cancel(); fadeWork = nil
        if isHidden { setMilkHidden(false); alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChatScrollerVisibility.revealDuration
            self.animator().alphaValue = 1
        }
    }

    func fadeWhenIdle(after delay: TimeInterval) {
        generation += 1
        fadeWork?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.fadeNow()
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func fadeNow() {
        generation += 1
        fadeWork?.cancel(); fadeWork = nil
        // AppKit's overlay machinery writes the scroller's alphaValue itself (it left
        // the bar at 1.0 while Milk kept it hidden). A faded bar is alpha 0 whether or
        // not it is hidden, so a later reveal always starts from invisible.
        guard !isHidden || alphaValue > 0.02 else { return }
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ChatScrollerVisibility.fadeDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == token, self.alphaValue < 0.02 else { return }
            // Out of sight and out of hit testing: an invisible knob must not be grabbable.
            self.setMilkHidden(true)
        })
    }

    override func mouseDown(with event: NSEvent) {
        revealByReader(); input?(true); super.mouseDown(with: event); input?(false)
        fadeWhenIdle(after: ChatScrollerVisibility.visibleFor)
    }
}
