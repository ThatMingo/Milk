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
        scroll.identifier = .init("milk.chat.transcript")
        scroll.setAccessibilityIdentifier("milk.chat.transcript")
        scroll.documentView = context.coordinator.document
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        scroll.changed = { [weak coordinator = context.coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator = context.coordinator] active in coordinator?.input(active) }
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
        if ChatScrollAudit.owner == coordinator.identity { ChatScrollAudit.snapshot = nil; ChatScrollAudit.owner = nil }
        scroll.changed = nil; scroll.input = nil
    }

    @MainActor final class Coordinator {
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
        var lastRows: [ChatTranscriptRow] = []
        var measuredCount = 0
        init() {
            document.keyboardScroll = { [weak self] delta, end in self?.keyboard(delta: delta, end: end) }
        }
        func update(_ parent: NativeChatTranscript, root: @escaping (ChatTranscriptRow) -> AnyView) {
            self.parent = parent; self.root = root
            guard let scroll else { return }
            if !initialized { follow.followsTail = parent.conversation.followsTail }
            let newWidth = max(1, scroll.contentView.bounds.width)
            guard newWidth > 1 else { return }
            // The representable can receive a provisional frame before SwiftUI
            // installs the pane's actual width. Do not consume a saved reading
            // offset as a different-width restore during that handoff.
            guard initialized || abs(newWidth - parent.paneWidth) < 1 else { return }
            let reflow = abs(width - newWidth) > 0.5
            if initialized && reflow && !committingReflow {
                pendingReflow?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let latest = self.parent, let root = self.root else { return }
                    self.committingReflow = true; self.update(latest, root: root); self.committingReflow = false
                }
                pendingReflow = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                // Keep existing measured pieces on screen throughout live resize.
                document.frame.size.width = newWidth
                let w = max(1, min(720, newWidth - (parent.narrow ? 40 : 64)))
                for host in hosts.values { host.frame.origin.x = (newWidth - w) / 2; host.frame.size.width = w }
                return
            }
            let changed = lastRows != parent.rows || refreshEnvironment
            let resized = viewport != scroll.contentView.bounds.height
            guard changed || reflow || resized || !initialized else { return }
            let metric = ChatRenderMetrics.begin()
            defer { ChatRenderMetrics.end("document.layout", metric) }
            let oldOffset = scroll.contentView.bounds.minY
            let anchor = layout.anchor(offset: oldOffset)
            let anchorDelta = anchor.flatMap { layout.offset(id: $0.id) }.map { oldOffset - $0 } ?? 0
            let oldRows = Dictionary(uniqueKeysWithValues: lastRows.map { ($0.id, $0) })
            updating = true
            width = newWidth
            viewport = scroll.contentView.bounds.height
            let contentWidth = max(1, min(720, width - (parent.narrow ? 40 : 64)))
            var geometry: [ChatTranscriptLayout.Row] = []
            measuredCount = 0
            for row in parent.rows {
                let h: Double
                if let cached = parent.session.heights[row.id], cached.0 == row.content, cached.1 == contentWidth { h = cached.2 }
                else if case .markdown(let block) = row.content, let cached = parent.session.sharedMarkdownHeights[contentWidth]?[block] { h = cached }
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
                    if case .markdown(let block) = row.content { parent.session.sharedMarkdownHeights[contentWidth, default: [:]][block] = h }
                }
                parent.session.heights[row.id] = (row.content, contentWidth, h)
                geometry.append(.init(id: row.id, owner: row.owner, height: h, gap: row.gap))
                if let host = hosts[row.id], reflow || refreshEnvironment || oldRows[row.id]?.content != row.content { host.rootView = root(row); hostedContent[row.id] = row.content }
            }
            if parent.session.sharedMarkdownHeights.count > 3 {
                parent.session.sharedMarkdownHeights = parent.session.sharedMarkdownHeights.filter { $0.key == contentWidth }
            }
            let liveIDs = Set(parent.rows.map(\.id))
            parent.session.heights = parent.session.heights.filter { liveIDs.contains($0.key) }
            for host in measuring.values { host.rootView = AnyView(EmptyView()) }
            layout.replace(geometry)
            lastRows = parent.rows
            document.frame = .init(x: 0, y: 0, width: width, height: max(layout.height, scroll.contentView.bounds.height))
            let target: Double
            if follow.followsTail { target = maximumOffset }
            else if initialized, let anchor, let restored = layout.offset(id: anchor.id, fraction: reflow ? anchor.fraction : 0) { target = restored + (reflow ? 0 : anchorDelta) }
            else if let id = parent.conversation.scrollAnchor, let savedWidth = parent.conversation.scrollWidth, abs(savedWidth - width) > 1, contentWidth < 720,
                    let restored = layout.offset(id: id) { target = restored }
            else { target = parent.conversation.scrollOffset ?? 0 }
            scroll.contentView.scroll(to: .init(x: 0, y: min(maximumOffset, max(0, target))))
            scroll.reflectScrolledClipView(scroll.contentView)
            initialized = true
            refreshEnvironment = false
            // Geometry replacement is layout, never user intent.
            let wasInput = follow.userScrolling; follow.userScrolling = false; follow.update(metrics); follow.userScrolling = wasInput
            materialize()
            updating = false
            installAudit()
            schedulePersist()
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
            case .markdown(let block):
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
            let contentWidth = max(1, min(720, width - (parent.narrow ? 40 : 64)))
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
        func input(_ active: Bool) {
            pendingInput?.cancel()
            if active { follow.userScrolling = true }
            else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.follow.update(self.metrics); self.follow.userScrolling = false; self.persist()
                }
                pendingInput = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        }
        func keyboard(delta: Double, end: Bool?) {
            guard let scroll else { return }
            input(true)
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
                        "readingTarget": visible.first.map { self.lastRows[$0].id } ?? "", "projectedItems": parent.session.projection.items(messages: parent.conversation.messages, activities: parent.conversation.activities).count,
                        "logicalRows": self.lastRows.count, "materialized": self.hosts.count, "visibleRange": [range.lowerBound, range.upperBound],
                        "materializedRange": [self.layout.range(offset: self.metrics.offset, viewport: self.metrics.viewportHeight, overscan: max(600, self.metrics.viewportHeight)).lowerBound, self.layout.range(offset: self.metrics.offset, viewport: self.metrics.viewportHeight, overscan: max(600, self.metrics.viewportHeight)).upperBound],
                        "measuredThisLayout": self.measuredCount, "heightCacheCount": parent.session.heights.count, "measurementHosts": self.measuring.count]
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
    override func layout() { super.layout(); changed?() }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0 else { super.scrollWheel(with: event); return }
        input?(true)
        // Vertical gestures belong to the transcript document, even above a
        // nested horizontal code scroller. Native wheel deltas already include
        // the system's direction/acceleration and momentum events.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : verticalLineScroll
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
    override func mouseDown(with event: NSEvent) {
        input?(true); super.mouseDown(with: event); input?(false)
    }
}
