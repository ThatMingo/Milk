import XCTest
import AppKit
import SwiftUI
@testable import Milk

/// TEMPORARY diagnostic probe (not a regression test): compares the height the
/// transcript measures with what the mounted native text actually lays out.
private struct ProbeRowView: View {
    let row: ChatTranscriptRow
    var body: some View {
        Group {
            switch row.content {
            case .user(let message): SelectableContent(text: message.text).fixedSize(horizontal: false, vertical: true)
            case .header(let turn): AgentResponseHeader(response: turn)
            case .markdown(let block, _): AgentMarkdownPiece(block: block).font(.system(size: 14)).textSelection(.enabled)
            case .thinking(let block, let label, let expanded, let active):
                AgentThinkingContent(block: block, label: label, expanded: expanded, active: active, toggle: {})
            case .activity(let activities, let expanded, let outputs):
                AgentActivityGroupContent(activities: activities, expanded: expanded, outputs: outputs, toggle: {}, toggleOutput: { _ in })
            case .changes: Text("changed")
            case .empty(let text): SelectableContent(text: text).fixedSize(horizontal: false, vertical: true)
            case .notice(let text): Text(text)
            case .error(let text): Text(text)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private func probeTextViews(in view: NSView) -> [NSTextView] {
    var found: [NSTextView] = []
    for sub in view.subviews {
        if let text = sub as? NSTextView { found.append(text) }
        found.append(contentsOf: probeTextViews(in: sub))
    }
    return found
}

@MainActor final class ChatDriftProbeTests: XCTestCase {
    /// A hosting view only materialises its NSViewRepresentable content once it is
    /// attached to a window and has been laid out, so the probe keeps the transcript
    /// in an offscreen window and reads the real NSTextView layout.
    var windows: [NSWindow] = []
    var observers: [NSObjectProtocol] = []
    var observer: NSObjectProtocol?
    func makeFixture(width: CGFloat = 700, height: CGFloat = 600) -> (ChatTranscriptSession, NativeChatTranscript.Coordinator, TranscriptScrollView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let session = ChatTranscriptSession()
        let coordinator = NativeChatTranscript.Coordinator()
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = coordinator.document
        coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView?.addSubview(scroll)
        // Wire the callbacks and notifications TranscriptScrollView uses in the app,
        // otherwise a synthetic wheel event never reaches the coordinator.
        scroll.changed = { [weak coordinator] in coordinator?.scrolled() }
        scroll.input = { [weak coordinator] active in coordinator?.input(active) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.scrolled() }
        }
        window.orderFrontRegardless()
        windows.append(window)
        window.layoutIfNeeded()
        window.display()
        window.displayIfNeeded()
        return (session, coordinator, scroll)
    }
    func parent(_ session: ChatTranscriptSession, _ conversation: SessionConversation) -> NativeChatTranscript {
        NativeChatTranscript(rows: session.rows(conversation, empty: ""), session: session, conversation: conversation,
                             narrow: false, sessionID: 0, paneWidth: 700, remember: { _, _, _, _ in },
                             content: { row in AnyView(ProbeRowView(row: row)) })
    }
    func layoutFor(_ coordinator: NativeChatTranscript.Coordinator, in document: NSView, host: NSView) -> [(view: NSTextView, top: Double, height: Double, viewWidth: Double, containerWidth: Double, used: Double, extra: Double)] {
        var out: [(NSTextView, Double, Double, Double, Double, Double, Double)] = []
        host.layoutSubtreeIfNeeded()
        for text in probeTextViews(in: host) {
            guard let container = text.textContainer, let manager = text.layoutManager else { continue }
            manager.ensureLayout(for: container)
            let origin = document.convert(text.textContainerOrigin, from: text)
            var laid = manager.usedRect(for: container).height
            let extra = text.string.hasSuffix("\n") ? manager.extraLineFragmentRect.height : 0
            laid -= extra
            out.append((text, Double(origin.y), Double(text.frame.height), Double(text.frame.width), Double(container.containerSize.width), Double(laid), Double(extra)))
        }
        return out
    }

    /// Streaming Thinking: measured row height vs the text the mounted view lays out.
    @MainActor func testProbeStreamingThinking() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        var conversation = SessionConversation()
        conversation.messages = [message]
        var chars = 0
        let chunk = "Reasoning about the workspace and which file to inspect next. \n"
        for frame in 0..<160 {
            let lines = 1 + (frame % 3)
            let delta = String(repeating: chunk, count: lines)
            chars += delta.count
            message.apply(.init(messageID: "turn-1", index: 0, kind: .thinking, text: delta))
            conversation.messages = [message]
            coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
            scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
            scroll.reflectScrolledClipView(scroll.contentView)
            coordinator.scrolled()
            if frame == 20 {
                guard let host = coordinator.hosts["turn-1-block-0"] else { return }
                host.layoutSubtreeIfNeeded()
                var tree: [String] = []
                func walk(_ view: NSView, _ depth: Int) {
                    if depth > 8 { return }
                    tree.append(String(repeating: "  ", count: depth) + String(describing: type(of: view)) + " frame=" + String(describing: view.frame))
                    for sub in view.subviews { walk(sub, depth + 1) }
                }
                walk(host, 0)
                print("thinking host tree frame=" + String(describing: host.frame) + "\n" + tree.joined(separator: "\n"))
            }
            if frame % 20 == 0 || frame == 159 {
                guard let host = coordinator.hosts["turn-1-block-0"] else { XCTFail("thinking not mounted"); return }
                let measured = session.heights["turn-1-block-0"]?.2 ?? -1
                for entry in layoutFor(coordinator, in: coordinator.document, host: host) {
                    let textBottom = entry.top + entry.used
                    let hostBottom = Double(host.frame.maxY)
                    print(String(format: "frame %d chars %d measured %g hostH %g textH %g viewW %g containerW %g used %g extra %g | clip %g blank %g | doc %g max %g offset %g gapBottom %g",
                                 frame, chars, measured, Double(host.frame.height), entry.height, entry.viewWidth, entry.containerWidth, entry.used, entry.extra,
                                 max(0, textBottom - hostBottom), max(0, hostBottom - textBottom),
                                 coordinator.document.frame.height, coordinator.maximumOffset, Double(scroll.contentView.bounds.minY),
                                 coordinator.document.frame.height - textBottom))
                }
            }
        }
    }

    /// Long settled transcript: does any piece end up with text that does not fit
    /// the height its measurement reserved?
    @MainActor func testProbeSettledTranscript() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "")
        message.blocks = [
            .init(id: "turn-1-block-0", index: 0, kind: .thinking, text: String(repeating: "Reasoning sentence about the fixture with a long tail. \n", count: 300)),
            .init(id: "turn-1-block-1", index: 1, kind: .text, text: AgentMarkdownMemory.answer),
        ]
        var conversation = SessionConversation()
        conversation.messages = [message]
        coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
        scroll.contentView.scroll(to: .init(x: 0, y: coordinator.maximumOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.scrolled()
        var worstClip = 0.0, worstBlank = 0.0, worstWidthMismatch = 0.0
        for (id, host) in coordinator.hosts {
            for entry in layoutFor(coordinator, in: coordinator.document, host: host) {
                worstClip = max(worstClip, entry.top + entry.used - Double(host.frame.maxY))
                worstBlank = max(worstBlank, Double(host.frame.maxY) - (entry.top + entry.used))
                worstWidthMismatch = max(worstWidthMismatch, abs(entry.viewWidth - entry.containerWidth))
            }
        }
        let audit = coordinator.visibleCoverageAudit()
        print("settled: mounted \(coordinator.hosts.count) worstClip \(worstClip) worstBlank \(worstBlank) worstWidthMismatch \(worstWidthMismatch) audit \(audit)")
        // Every row, mounted or not, measured height vs the height SwiftUI gives inside the host.
        for row in coordinator.lastRows {
            guard let host = coordinator.hosts[row.id] else { continue }
            let measured = session.heights[row.id]?.2 ?? -1
            print(String(format: "row %@ measured %g hostH %g", row.id, measured, Double(host.frame.height)))
        }
    }

    /// Live pane resize: is the text container width left stale, and does the
    /// reflow actually re-measure every row?
    @MainActor func testProbeResizeReflow() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "")
        message.blocks = [
            .init(id: "turn-1-block-0", index: 0, kind: .thinking, text: String(repeating: "Reasoning sentence about the fixture with a long tail. \n", count: 120)),
            .init(id: "turn-1-block-1", index: 1, kind: .text, text: String(repeating: "Answer paragraph that wraps across the pane width many times. ", count: 120)),
        ]
        var conversation = SessionConversation()
        conversation.messages = [message]
        coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
        let before = coordinator.document.frame.height
        for width in [660.0, 620.0, 580.0, 540.0, 500.0] {
            scroll.frame.size.width = width
            scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: width, height: 600)
            coordinator.scrolled()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let audit = coordinator.visibleCoverageAudit()
        var widths: [String] = []
        for (id, host) in coordinator.hosts.sorted(by: { $0.key < $1.key }) {
            for entry in layoutFor(coordinator, in: coordinator.document, host: host) {
                widths.append("\(id): view \(entry.viewWidth) container \(entry.containerWidth) hostW \(host.frame.width) used \(entry.used) hostH \(host.frame.height)")
            }
        }
        print("resize: before \(before) after \(coordinator.document.frame.height) width \(coordinator.width) audit \(audit)")
        widths.forEach { print("  \($0)") }
    }

    /// Direct comparison of the transcript measurement formula against what an
    /// NSTextView configured exactly like SelectableContent actually lays out.
    private func measure(_ text: String, width: CGFloat, size: CGFloat = 14, monospaced: Bool = false) -> [String: Double] {
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        view.textContainer?.containerSize = CGSize(width: width, height: 10_000)
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let value = NSMutableAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        view.textStorage?.setAttributedString(value)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let usedRaw = Double(view.layoutManager!.usedRect(for: view.textContainer!).height)
        let extra = text.hasSuffix("\n") ? Double(view.layoutManager!.extraLineFragmentRect.height) : 0
        var length = value.length
        while length > 0, (value.string as NSString).character(at: length - 1) == 0x0a { length -= 1 }
        let trimmed: NSAttributedString = length == value.length ? value : value.attributedSubstring(from: NSRange(location: 0, length: length))
        // The formula the transcript used before this change, kept here so the delta is visible.
        let oldReserve = ceil(trimmed.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
        // Production measurement: the same hosting controller the transcript asks.
        let host = NSHostingController(rootView: AnyView(SelectableContent(text: text, size: size, monospaced: monospaced).fixedSize(horizontal: false, vertical: true)))
        host.sizingOptions = []
        let reserved = host.sizeThatFits(in: .init(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let window = measurementWindow()
        window.contentView = host.view
        window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()
        var laidOut = 0.0
        func scan(_ view: NSView) {
            if let text = view as? NSTextView, let container = text.textContainer, let manager = text.layoutManager {
                container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
                manager.ensureLayout(for: container)
                var used = manager.usedRect(for: container).height
                let extra = manager.extraLineFragmentRect
                if !extra.isEmpty { used -= extra.height }
                laidOut = used
                return
            }
            view.subviews.forEach { scan($0) }
        }
        scan(host.view)
        return ["oldReserve": oldReserve, "reserve": reserved, "laidOut": laidOut, "usedRaw": usedRaw, "extra": extra, "usedTrimmed": usedRaw - extra]
    }

    private func measurementWindow() -> NSWindow {
        if let window = windows.first(where: { $0.title == "measurement" }) { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 4_000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "measurement"
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    @MainActor func testProbeMeasurementCorpus() {
        let corpus: [(String, String, [String: Double])] = [
            ("one line", "single short line", [:]),
            ("one line +nl", "single short line\n", [:]),
            ("three lines +nl", "first line\nsecond line\nthird line\n", [:]),
            ("blank line inside", "first line\n\nsecond line\n", [:]),
            ("ends with one blank", "first line\n\n", [:]),
            ("ends with two blanks", "first line\n\n\n", [:]),
            ("wrapped paragraph", String(repeating: "The workspace measures each piece once per width and reuses it. ", count: 12), [:]),
            ("trailing spaces", String(repeating: "line with trailing spaces   \n", count: 6), [:]),
            ("tab indented", "func run() {\n\tlet x = 1\n\t\tprint(x)\n}\n", [:]),
            ("long token", String(repeating: "a", count: 240) + "\n", [:]),
            ("cjk", String(repeating: "这是一段很长的中文思考内容，需要换行处理。", count: 6) + "\n", [:]),
            ("emoji", String(repeating: "checking 🔍 the build 🧪 now\n", count: 5), [:]),
            ("empty", "", [:]),
            ("newline only", "\n", [:]),
            ("monospaced code", String(repeating: "swift test --filter ChatGeometryTests --parallel\n", count: 8), ["size": 12, "monospaced": 1]),
            ("activity output", "Command\n\n" + String(repeating: "warning: something happened in the build log\n", count: 30), ["size": 11.5, "monospaced": 1]),
        ]
        for width in [624.0, 420.0] {
            for (name, text, options) in corpus {
                let m = measure(text, width: width, size: options["size"] ?? 14, monospaced: (options["monospaced"] ?? 0) != 0)
                print(String(format: "corpus w%g %@ oldReserve=%g reserved=%g laidOut=%g usedRaw=%g extra=%g under=%g",
                             width, name.padding(toLength: 18, withPad: " ", startingAt: 0),
                             m["oldReserve"]!, m["reserve"]!, m["laidOut"]!, m["usedRaw"]!, m["extra"]!, m["laidOut"]! - m["reserve"]!))
            }
        }
    }

    // MARK: - Scroll-state drift probes

    private struct Scenario {
        var name: String
        var frames: Int = 120
        var userScrollAt: Int? = nil
        var userScrollTravel: Double = 0
        var resizeAt: Int? = nil
        var resizeWidth: CGFloat = 0
        var viewportChangeAt: Int? = nil
        var toggleAt: Int? = nil
        var continuousResize: CGFloat = 0
        var continuousFrom: Int? = nil
        var auditEachFrame = false
        var traceFrom: Int? = nil
        var traceTo: Int? = nil
        var thinkingBlocks: Int = 1
        var markdownTail: Bool = false
    }

    /// Runs a realistic streaming session and reports where the scroll state stops
    /// matching the document geometry it just computed.
    @MainActor private func run(_ scenario: Scenario) {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = (0..<scenario.thinkingBlocks).map { i in
            AgentContentBlock(id: "turn-1-block-\(i)", index: i, kind: i == scenario.thinkingBlocks - 1 && scenario.markdownTail ? .text : .thinking, text: "", streaming: true)
        }
        var conversation = SessionConversation()
        conversation.messages = [message]
        var framesSinceAnchor = 0
        var anchor: String?
        var anchorOrigin: Double?
        var anchorOffset: Double?
        var worstTailGap = 0.0, worstFollowLost = 0, worstAnchorDrift = 0.0, worstOffsetDrift = 0.0
        var worstClip = 0.0, worstBlank = 0.0, worstHole = 0.0, framesWithStaleWidth = 0
        var firstTailGap = -1, firstFollowLost = -1, firstAnchorDrift = -1
        var widths: [CGFloat] = [700]
        for frame in 0..<scenario.frames {
            if let at = scenario.resizeAt, frame == at {
                scroll.frame.size.width = scenario.resizeWidth
                scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: scenario.resizeWidth, height: scroll.contentView.bounds.height)
                widths.append(scenario.resizeWidth)
            }
            if let at = scenario.viewportChangeAt, frame == at {
                scroll.frame.size.height = 480
                scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: scroll.contentView.bounds.width, height: 480)
            }
            let index = min(frame % scenario.thinkingBlocks, message.blocks!.count - 1)
            let kind: AgentContentBlock.Kind = index == message.blocks!.count - 1 && scenario.markdownTail ? .text : .thinking
            message.apply(.init(messageID: "turn-1", index: index, kind: kind, text: String(repeating: "Reasoning about the next file to read and how to wire it up. \n", count: 1 + frame % 3)))
            conversation.messages = [message]
            if let at = scenario.toggleAt, frame == at {
                session.choices["turn-1"] = !(session.choices["turn-1"] ?? false)
            }
            coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
            // Wheel input the way TranscriptScrollView delivers it.
            if let at = scenario.userScrollAt, frame == at, scenario.userScrollTravel > 0 {
                coordinator.input(true)
                let y = max(0, coordinator.metrics.offset - scenario.userScrollTravel)
                scroll.contentView.scroll(to: .init(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                coordinator.input(false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                anchor = coordinator.layout.anchor(offset: coordinator.metrics.offset)?.id
                anchorOrigin = coordinator.layout.offset(id: anchor!)
                anchorOffset = coordinator.metrics.offset
                framesSinceAnchor = 0
            }
            if let from = scenario.continuousFrom, let delta = Optional(scenario.continuousResize), delta != 0, frame >= from {
                let newWidth = max(320, scroll.contentView.bounds.width - delta)
                scroll.frame.size.width = newWidth
                scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: newWidth, height: scroll.contentView.bounds.height)
            }
            // A real pane resize delivers bounds changes continuously; the transcript
            // defers its remeasure. Ask for the audit the way the verifier does.
            if scenario.auditEachFrame {
                let audit = coordinator.visibleCoverageAudit()
                let clip = audit["clippedPoints"] ?? 0, blank = audit["trailingBlank"] ?? 0, hole = audit["unmountedGap"] ?? 0
                worstClip = max(worstClip, clip); worstBlank = max(worstBlank, blank); worstHole = max(worstHole, hole)
                if abs(coordinator.width - scroll.contentView.bounds.width) > 0.5 { framesWithStaleWidth += 1 }
            }
            let metrics = coordinator.metrics
            if let from = scenario.traceFrom, let to = scenario.traceTo, frame >= from, frame <= to {
                print(String(format: "  trace frame %d offset %g doc %g max %g followsTail %d userScrolling %d gap %g hosts %d", frame, metrics.offset, metrics.contentHeight, coordinator.maximumOffset, coordinator.follow.followsTail ? 1 : 0, coordinator.follow.userScrolling ? 1 : 0, metrics.distanceFromBottom, coordinator.hosts.count))
            }
            let gap = metrics.distanceFromBottom
            if gap > 0.5 {
                worstTailGap = max(worstTailGap, gap)
                if firstTailGap < 0 { firstTailGap = frame }
            }
            if scenario.userScrollAt == nil && gap > 0.5 { }
            if coordinator.follow.followsTail == false && coordinator.metrics.nearBottom { worstFollowLost += 1; if firstFollowLost < 0 { firstFollowLost = frame } }
            if let id = anchor, let original = anchorOrigin, let o = coordinator.layout.offset(id: id) {
                framesSinceAnchor += 1
                // The reader stays parked on the same piece: its absolute origin must not move
                // unless content above it changed.
                let drift = o - original
                if abs(drift) > abs(worstAnchorDrift) { worstAnchorDrift = drift }
                worstOffsetDrift = max(worstOffsetDrift, abs(metrics.offset - anchorOffset!))
            }
            if let at = scenario.userScrollAt, scenario.userScrollTravel > 0, frame == at + 20, let id = anchor {
                print("  [\(scenario.name)] anchor \(id) origin \(anchorOrigin!) -> \(coordinator.layout.offset(id: id)!) offset \(anchorOffset!) -> \(coordinator.metrics.offset) followsTail \(coordinator.follow.followsTail)")
            }
        }
        print("[\(scenario.name)] clip \(worstClip) blank \(worstBlank) hole \(worstHole) staleWidthFrames \(framesWithStaleWidth) measuredHosts \(coordinator.measuring.count) frames \(scenario.frames) doc \(coordinator.document.frame.height) offset \(coordinator.metrics.offset) maxOffset \(coordinator.maximumOffset) firstTailGap \(firstTailGap) worstTailGap \(worstTailGap) worstAnchorDrift \(worstAnchorDrift) worstOffsetDrift \(worstOffsetDrift) nearBottomButNotFollowing \(worstFollowLost)")
    }

    @MainActor func testProbeScrollStateMatrix() {
        run(Scenario(name: "tail-follow single thinking"))
        run(Scenario(name: "tail-follow three thinking blocks", thinkingBlocks: 3))
        run(Scenario(name: "tail-follow thinking then markdown tail", thinkingBlocks: 2, markdownTail: true))
        run(Scenario(name: "resize mid stream", resizeAt: 40, resizeWidth: 520))
        run(Scenario(name: "viewport change mid stream", viewportChangeAt: 40))
        run(Scenario(name: "user scrolls up 90 then idles", userScrollAt: 40, userScrollTravel: 90, traceFrom: 38, traceTo: 50))
        run(Scenario(name: "user scrolls up 90 then resize", userScrollAt: 40, userScrollTravel: 90, resizeAt: 60, resizeWidth: 540))
        run(Scenario(name: "user scrolls up 20 (inside hysteresis)", userScrollAt: 40, userScrollTravel: 20))
        run(Scenario(name: "disclosure toggle mid stream", toggleAt: 60))
        run(Scenario(name: "continuous resize every frame", continuousResize: 2, continuousFrom: 20, auditEachFrame: true))
        run(Scenario(name: "continuous resize, wide shrink", continuousResize: 6, continuousFrom: 20, auditEachFrame: true))
        run(Scenario(name: "audit each frame, stable width", auditEachFrame: true))
    }

    /// A long settled transcript under streaming load: do row heights that already
    /// reached the height cache stay identical, and does the layout keep the reader's
    /// piece at the same absolute origin? Cache eviction is the condition that makes
    /// a long session re-measure pieces it measured once.
    @MainActor func testProbeSettledHeightStability() {
        let (session, coordinator, scroll) = makeFixture()
        var messages: [AgentMessage] = []
        for turn in 0..<8 {
            var user = AgentMessage(id: "u\(turn)", role: "user", text: "Inspect turn \(turn) and describe the change needed in Sources/Milk/ChatPanel.swift for this case.")
            messages.append(user)
            var assistant = AgentMessage(id: "turn-\(turn)", role: "assistant", text: "")
            assistant.blocks = [
                .init(id: "turn-\(turn)-block-0", index: 0, kind: .thinking, text: String(repeating: "Thinking about turn \(turn): which invariant keeps the layout honest? \n", count: 4)),
                .init(id: "turn-\(turn)-block-1", index: 1, kind: .text, text: "Paragraph for turn \(turn).\n\n" + String(repeating: "Measured once per width and reused while the width is stable. ", count: 3 + turn) + "\n\n- item one\n- item two\n\n" + String(repeating: "let value = measure(row)\n", count: 3)),
            ]
            messages.append(assistant)
        }
        var live = AgentMessage(id: "turn-live", role: "assistant", text: "", streaming: true)
        live.blocks = [.init(id: "turn-live-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        var conversation = SessionConversation()
        conversation.messages = messages + [live]
        for key in messages.compactMap({ $0.id.hasPrefix("turn-") ? $0.id : nil }) { session.choices[key] = true }
        coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
        // Park the reader on a settled piece in the middle of the transcript.
        let parked = "turn-3-block-1-markdown-0"
        guard let parkedOrigin = coordinator.layout.offset(id: parked) else { return XCTFail("parked row missing") }
        coordinator.input(true)
        scroll.contentView.scroll(to: .init(x: 0, y: parkedOrigin))
        scroll.reflectScrolledClipView(scroll.contentView)
        coordinator.input(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var firstHeights: [String: Double] = [:]
        for (id, entry) in session.heights { firstHeights[id] = entry.2 }
        var changedRows: [String] = []
        var originDrift = 0.0, maxMeasured = 0, cacheEntries = 0
        for frame in 0..<80 {
            live.apply(.init(messageID: "turn-live", index: 0, kind: .thinking, text: String(repeating: "Streaming tail that keeps the document growing while the reader is parked. \n", count: 1 + frame % 4)))
            conversation.messages = messages + [live]
            coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
            maxMeasured = max(maxMeasured, coordinator.measuredCount)
            cacheEntries = max(cacheEntries, session.cacheEntries)
            if let o = coordinator.layout.offset(id: parked) { originDrift = max(originDrift, abs(o - parkedOrigin)) }
            for (id, entry) in session.heights where firstHeights[id] != nil {
                if abs(entry.2 - firstHeights[id]!) > 0.01, !changedRows.contains(id) { changedRows.append(id) }
            }
            let audit = coordinator.visibleCoverageAudit()
            if (audit["clippedPoints"] ?? 0) > 1 { print("clip at frame \(frame) \(audit)") }
        }
        print(String(format: "settled stability: rows %d firstMeasured %d maxMeasuredPerFrame %d cacheEntries %d originDrift %g offset %g parkedOrigin %g changedRows %@",
                     coordinator.lastRows.count, firstHeights.count, maxMeasured, cacheEntries, originDrift, coordinator.metrics.offset, parkedOrigin, changedRows))
    }

    /// Live pane narrowing while output streams: the transcript defers its remeasure,
    /// but the deferred window must never leave mounted text taller than the frame the
    /// layout gave it, and it must recover once the width stops changing.
    @MainActor func testProbeLiveResizeWindow() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = [
            .init(id: "turn-1-block-0", index: 0, kind: .thinking, text: "", streaming: true),
            .init(id: "turn-1-block-1", index: 1, kind: .text, text: String(repeating: "Answer paragraph that has to rewrap as the pane narrows many times. ", count: 30)),
        ]
        var conversation = SessionConversation()
        conversation.messages = [message]
        coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
        var worstClip = 0.0, worstHole = 0.0, staleWidthFrames = 0
        for (frame, width) in stride(from: 690.0, through: 420.0, by: -5).enumerated() {
            message.apply(.init(messageID: "turn-1", index: 0, kind: .thinking, text: "Streaming while the pane is being dragged. \n"))
            conversation.messages = [message]
            scroll.frame.size.width = width
            scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: width, height: scroll.contentView.bounds.height)
            coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
            let audit = coordinator.visibleCoverageAudit()
            worstClip = max(worstClip, audit["clippedPoints"] ?? 0)
            worstHole = max(worstHole, audit["unmountedGap"] ?? 0)
            if abs(coordinator.width - scroll.contentView.bounds.width) > 0.5 { staleWidthFrames += 1 }
            if frame % 10 == 0 {
                var detail: [String] = []
                for (id, host) in coordinator.hosts.sorted(by: { $0.key < $1.key }) {
                    host.layoutSubtreeIfNeeded()
                    var entry = "\(id) host \(host.frame.width)x\(host.frame.height)"
                    for view in probeTextViews(in: host) {
                        guard let text = view as? NSTextView, let container = text.textContainer, let manager = text.layoutManager else { continue }
                        manager.ensureLayout(for: container)
                        let used = Double(manager.usedRect(for: container).height)
                        entry += " text \(text.frame.width)x\(text.frame.height) used \(used)"
                    }
                    detail.append(entry)
                }
                print(String(format: "  drag frame %d width %g coordinatorWidth %g mounted %d doc %g measured %d audit %@", frame, scroll.contentView.bounds.width, coordinator.width, coordinator.hosts.count, coordinator.document.frame.height, coordinator.measuredCount, audit))
                detail.forEach { print("    \($0)") }
            }
        }
        // The pane stops moving; the deferred remeasure gets its turn at the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let settled = coordinator.visibleCoverageAudit()
        print(String(format: "live resize: worstClipDuringDrag %g worstHoleDuringDrag %g staleWidthFrames %d | after settle clip %g blank %g hole %g width %g/%g doc %g offset %g max %g measured %d",
                     worstClip, worstHole, staleWidthFrames, settled["clippedPoints"] ?? 0, settled["trailingBlank"] ?? 0, settled["unmountedGap"] ?? 0,
                     coordinator.width, scroll.contentView.bounds.width, coordinator.document.frame.height, coordinator.metrics.offset, coordinator.maximumOffset, coordinator.measuredCount))
    }

    /// A pane whose width keeps stepping (split-view drag, sidebar animation, a layout
    /// that toggles an inset) while output streams. Content must still render on every
    /// frame; deferring the remeasure must not defer the content itself.
    @MainActor func testProbeWidthOscillation() {
        let (session, coordinator, scroll) = makeFixture()
        session.choices["turn-1"] = true
        var message = AgentMessage(id: "turn-1", role: "assistant", text: "", streaming: true)
        message.blocks = [.init(id: "turn-1-block-0", index: 0, kind: .thinking, text: "", streaming: true)]
        var conversation = SessionConversation()
        conversation.messages = [message]
        coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
        var chars = 0, worstClip = 0.0, staleFrames = 0, measuredTotal = 0
        for frame in 0..<60 {
            let delta = "Oscillating pane width must not hide streamed output. \n"
            chars += delta.count
            message.apply(.init(messageID: "turn-1", index: 0, kind: .thinking, text: delta))
            conversation.messages = [message]
            let width: CGFloat = frame % 2 == 0 ? 700 : 686
            scroll.frame.size.width = width
            scroll.contentView.frame = NSRect(x: 0, y: scroll.contentView.bounds.minY, width: width, height: scroll.contentView.bounds.height)
            coordinator.update(parent(session, conversation), root: { AnyView(ProbeRowView(row: $0)) })
            let audit = coordinator.visibleCoverageAudit()
            worstClip = max(worstClip, audit["clippedPoints"] ?? 0)
            if abs(coordinator.width - scroll.contentView.bounds.width) > 0.5 { staleFrames += 1 }
            measuredTotal += coordinator.measuredCount
            if frame % 12 == 0 {
                let measured = session.heights["turn-1-block-0"]?.2 ?? -1
                print(String(format: "  oscillation frame %d chars %d width %g coordinatorWidth %g measured %g doc %g offset %g max %g clip %g", frame, chars, scroll.contentView.bounds.width, coordinator.width, measured, coordinator.document.frame.height, coordinator.metrics.offset, coordinator.maximumOffset, audit["clippedPoints"] ?? 0))
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print(String(format: "width oscillation: worstClip %g staleFrames %d measuredPerFrame %g final doc %g offset %g max %g chars %d",
                     worstClip, staleFrames, Double(measuredTotal) / 60.0, coordinator.document.frame.height, coordinator.metrics.offset, coordinator.maximumOffset, chars))
    }
}
