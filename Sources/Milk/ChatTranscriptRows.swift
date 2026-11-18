import SwiftUI

struct ChatTranscriptRow: Identifiable, Equatable {
    enum Content: Equatable {
        case user(AgentMessage)
        case header(AgentResponseTurn)
        case markdown(AgentMarkdownBlock, streaming: Bool)
        case thinking(AgentContentBlock, label: Bool, expanded: Bool, active: Bool)
        case activity([ChatActivityStep], expanded: Bool, outputs: Set<String>, thoughts: Set<String>)
        case changes([AgentFileChange])
        case notice(String)
        case error(String)
        case empty(String)
    }
    var id: String
    var owner: String
    var order: [Int]
    var gap: Double
    var content: Content
}

/// One step in an activity card, in exactly the order emitted by the agent.
enum ChatActivityStep: Identifiable, Equatable {
    case tool(AgentActivity)
    case thinking(AgentContentBlock)

    var id: String {
        switch self {
        case .tool(let activity): return "tool/" + activity.id
        case .thinking(let block): return "thinking/" + block.id
        }
    }
    var running: Bool {
        switch self {
        case .tool(let activity): return activity.status == .running || activity.status == .approval
        case .thinking(let block): return block.streaming
        }
    }
}

extension AgentResponseTurn {
    func activitySteps(in group: AgentResponseContentGroup) -> [ChatActivityStep] {
        let byID = Dictionary(activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return group.blocks.compactMap { block -> ChatActivityStep? in
            switch block.kind {
            case .activity:
                guard let id = block.activityID, let activity = byID[id] else { return nil }
                return .tool(activity)
            case .thinking: return .thinking(block)
            case .text: return nil
            }
        }
    }
}

/// Rendering state is local to Chat, keyed by session and stable transcript IDs.
/// Unmounting native views must not collapse disclosures or forget measurements.
@MainActor final class ChatTranscriptSession: ObservableObject {
    /// Bumped by user disclosure choices only. A disclosure changes geometry
    /// without moving the transcript tail, so the scroll owner needs to tell the
    /// two apart. Survives geometry eviction because choices do.
    private(set) var disclosureRevision = 0
    @Published var choices: [String: Bool] = [:] {
        didSet { if oldValue != choices { disclosureRevision += 1 } }
    }
    var projection = AgentTranscriptProjection()
    private var cached: [String: (AgentTranscriptItem, [String: Bool], [ChatTranscriptRow])] = [:]
    var heights: [String: (ChatTranscriptRow.Content, Double, Double)] = [:]
    var markdownHeights = ChatMarkdownHeightCache()
    /// Released when a render session stops being recently used, or when its
    /// workspace session closes. Disclosure choices are deliberately kept.
    func releaseGeometry() { heights.removeAll(); markdownHeights.removeAll(); cached.removeAll(); projection.reset() }
    /// Diagnostics only: text this render session retains beyond the conversation.
    var retainedBytes: Int { markdownHeights.retainedBytes + projection.retainedBytes }
    var cacheEntries: Int { markdownHeights.count }
    func rows(_ conversation: SessionConversation, empty: String) -> [ChatTranscriptRow] {
        let items = projection.items(messages: conversation.messages, activities: conversation.activities)
        var result: [ChatTranscriptRow] = []
        for (i, item) in items.enumerated() {
            let relevant = choices.filter { $0.key == item.id || $0.key.hasPrefix(item.id + "/") }
            var rows: [ChatTranscriptRow]
            if let hit = cached[item.id], hit.0 == item, hit.1 == relevant { rows = hit.2 }
            else {
                rows = []
                func add(_ id: String, _ content: ChatTranscriptRow.Content, _ order: [Int], gap: Double = 12) {
                    rows.append(.init(id: id, owner: item.id, order: order, gap: rows.isEmpty ? 22 : gap, content: content))
                }
                if let user = item.user { add(item.id, .user(user), [0]) }
                else if let turn = item.response {
                    add(item.id, .header(turn), [0])
                    let expanded = choices[item.id] ?? false
                    let groups = turn.presentationGroups
                    let firstThinking = groups.filter { !$0.isActivity }.flatMap(\.blocks).first(where: \.visibleThinking)?.id
                    for group in groups {
                        if group.isActivity {
                            let steps = turn.activitySteps(in: group)
                            let key = item.id + "/" + group.id
                            let open = choices[key] ?? steps.contains { $0.running }
                            let outputs = Set(steps.compactMap { step -> String? in
                                guard case .tool(let activity) = step, choices[item.id + "/output/" + activity.id] == true else { return nil }
                                return activity.id
                            })
                            let thoughts = Set(steps.compactMap { step -> String? in
                                guard case .thinking(let block) = step, choices[item.id + "/thinking/" + block.id] == true else { return nil }
                                return block.id
                            })
                            add(group.id, .activity(steps, expanded: open, outputs: outputs, thoughts: thoughts), [turn.blocks.firstIndex(where: { $0.id == group.id }) ?? 0])
                        } else {
                            for block in group.blocks {
                                let j = turn.blocks.firstIndex(where: { $0.id == block.id }) ?? 0
                                if block.kind == .text {
                                    for (k, piece) in AgentMarkdownBlock.parse(block.text).enumerated() {
                                        add(block.id + "-markdown-" + String(k), .markdown(piece, streaming: block.streaming), [j, k], gap: k == 0 ? 12 : 10)
                                    }
                                } else if block.visibleThinking && (expanded || block.id == firstThinking) {
                                    add(block.id, .thinking(block, label: block.id == firstThinking, expanded: expanded, active: turn.thinkingActive), [j])
                                }
                            }
                        }
                    }
                }
                cached[item.id] = (item, relevant, rows)
            }
            for j in rows.indices { rows[j].order.insert(i, at: 0) }
            result += rows
        }
        let live = Set(items.map(\.id))
        cached = cached.filter { live.contains($0.key) }
        func append(_ id: String, _ content: ChatTranscriptRow.Content) {
            result.append(.init(id: id, owner: id, order: [items.count, result.count], gap: 22, content: content))
        }
        if items.isEmpty { append("empty", .empty(empty)) }
        if !conversation.changes.isEmpty { append("changed-files", .changes(conversation.changes)) }
        if let notice = conversation.notice { append("notice", .notice(notice)) }
        if let error = conversation.error { append("error", .error(error)) }
        return result
    }
}

/// Identical settled Markdown pieces share one measurement at a given content
/// width. The cache is explicitly bounded: entries are evicted oldest-first once
/// either the entry or retained-text budget is exceeded, so a live stream that
/// re-measures a growing response thousands of times cannot retain every
/// intermediate prefix of that response.
struct ChatMarkdownHeightCache {
    /// Distinct pieces retained at a time, across all measured widths.
    static let entryLimit = 64
    /// Markdown text retained by cache keys, in UTF-8 bytes.
    static let characterLimit = 1 << 18
    /// Pane widths are quantized; older widths are dropped beyond this many.
    static let widthLimit = 3

    private(set) var widths: [Double: [AgentMarkdownBlock: Double]] = [:]
    private var order: [(width: Double, block: AgentMarkdownBlock, bytes: Int)] = []

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }
    var retainedBytes: Int { order.reduce(0) { $0 + $1.bytes } }

    func height(at width: Double, for block: AgentMarkdownBlock) -> Double? { widths[width]?[block] }

    mutating func setHeight(_ height: Double, at width: Double, for block: AgentMarkdownBlock) {
        let bytes = block.utf8Count
        // One oversized piece is measured on demand instead of evicting everything
        // else; keeping it here would defeat the budget on its own.
        guard bytes <= Self.characterLimit else { return }
        if widths[width]?[block] != nil { order.removeAll { $0.width == width && $0.block == block } }
        order.append((width, block, bytes))
        widths[width, default: [:]][block] = height
        if widths.count > Self.widthLimit {
            widths = widths.filter { $0.key == width }
            order.removeAll { $0.width != width }
        }
        while order.count > Self.entryLimit || retainedBytes > Self.characterLimit {
            guard let oldest = order.first else { break }
            order.removeFirst()
            widths[oldest.width]?.removeValue(forKey: oldest.block)
            if widths[oldest.width]?.isEmpty == true { widths[oldest.width] = nil }
        }
    }

    mutating func removeAll() { widths.removeAll(); order.removeAll() }
}

@MainActor final class ChatTranscriptStore {
    private var sessions: [Int: ChatTranscriptSession] = [:]
    private var recent: [Int] = []
    /// Sessions currently holding rendering state, for tests and verification only.
    var retainedSessions: Set<Int> { Set(sessions.keys) }
    func session(_ id: Int) -> ChatTranscriptSession {
        recent.removeAll { $0 == id }; recent.append(id)
        if recent.count > 4 { sessions[recent.removeFirst()]?.releaseGeometry() }
        if let value = sessions[id] { return value }
        let value = ChatTranscriptSession(); sessions[id] = value
        return value
    }
    /// A session that is no longer open keeps no rendering state at all: its
    /// projection copy, measurements, row cache and disclosures are all local.
    func retain(open ids: Set<Int>) {
        for id in Set(sessions.keys).subtracting(ids) { sessions[id] = nil }
        recent.removeAll { !ids.contains($0) }
    }
}
