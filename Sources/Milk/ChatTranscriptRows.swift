import SwiftUI

struct ChatTranscriptRow: Identifiable, Equatable {
    enum Content: Equatable {
        case user(AgentMessage)
        case header(AgentResponseTurn)
        case markdown(AgentMarkdownBlock)
        case thinking(AgentContentBlock, label: Bool, expanded: Bool, active: Bool)
        case activity([AgentActivity], expanded: Bool, outputs: Set<String>)
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

/// Rendering state is local to Chat, keyed by session and stable transcript IDs.
/// Unmounting native views must not collapse disclosures or forget measurements.
@MainActor final class ChatTranscriptSession: ObservableObject {
    @Published var choices: [String: Bool] = [:]
    var projection = AgentTranscriptProjection()
    private var cached: [String: (AgentTranscriptItem, [String: Bool], [ChatTranscriptRow])] = [:]
    var heights: [String: (ChatTranscriptRow.Content, Double, Double)] = [:]
    var sharedMarkdownHeights: [Double: [AgentMarkdownBlock: Double]] = [:]
    func releaseGeometry() { heights.removeAll(); sharedMarkdownHeights.removeAll(); cached.removeAll() }
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
                    let firstThinking = turn.blocks.first(where: \.visibleThinking)?.id
                    for group in turn.presentationGroups {
                        if group.isActivity {
                            let activities = group.blocks.compactMap { block in turn.activities.first { $0.id == block.activityID } }
                            let key = item.id + "/" + group.id
                            let open = choices[key] ?? activities.contains { $0.status == .running || $0.status == .approval }
                            let outputs = Set(activities.filter { choices[item.id + "/output/" + $0.id] == true }.map(\.id))
                            add(group.id, .activity(activities, expanded: open, outputs: outputs), [turn.blocks.firstIndex(where: { $0.id == group.id }) ?? 0])
                        } else {
                            for block in group.blocks {
                                let j = turn.blocks.firstIndex(where: { $0.id == block.id }) ?? 0
                                if block.kind == .text {
                                    for (k, piece) in AgentMarkdownBlock.parse(block.text).enumerated() {
                                        add(block.id + "-markdown-" + String(k), .markdown(piece), [j, k], gap: k == 0 ? 12 : 10)
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

@MainActor final class ChatTranscriptStore {
    private var sessions: [Int: ChatTranscriptSession] = [:]
    private var recent: [Int] = []
    func session(_ id: Int) -> ChatTranscriptSession {
        recent.removeAll { $0 == id }; recent.append(id)
        if recent.count > 4 { sessions[recent.removeFirst()]?.releaseGeometry() }
        if let value = sessions[id] { return value }
        let value = ChatTranscriptSession(); sessions[id] = value
        return value
    }
}
