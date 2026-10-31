import Foundation

/// Ordered, visible provider content. Opaque thinking signatures never enter this model.
struct AgentContentBlock: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, thinking, activity }
    var id: String
    var index: Int
    var kind: Kind
    var text = ""
    var activityID: String?
    var streaming = false
    var redacted = false
    var visibleThinking: Bool { kind == .thinking && !redacted && (streaming || !text.isEmpty) }
}
struct AgentContentDelta {
    var messageID: String
    var index: Int
    var kind: AgentContentBlock.Kind
    var text = ""
    var replace = false
    var finished = false
    var redacted = false
    var activityID: String?
}
extension AgentMessage {
    mutating func apply(_ delta: AgentContentDelta) {
        var content = blocks ?? []
        let position: Int
        if let existing = content.firstIndex(where: { $0.index == delta.index }) { position = existing }
        else {
            content.append(.init(id: "\(id)-block-\(delta.index)", index: delta.index, kind: delta.kind))
            position = content.count - 1
        }
        content[position].kind = delta.kind
        if delta.redacted { content[position].redacted = true; content[position].text = "" }
        else if !content[position].redacted {
            if delta.replace { content[position].text = delta.text } else { content[position].text += delta.text }
        }
        content[position].streaming = !delta.finished
        if let toolID = delta.activityID { content[position].activityID = toolID }
        blocks = content.sorted { $0.index < $1.index }
        text = blocks!.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
    }
}

struct AgentResponseTurn: Identifiable, Equatable {
    var id: String
    var blocks: [AgentContentBlock] = []
    var activities: [AgentActivity] = []
    var streaming = false
    var thinkingActive: Bool { blocks.contains { $0.visibleThinking && $0.streaming } }
    /// Normalize message blocks into visible units before grouping. Lifecycle/output updates
    /// resolve to the existing activity by ID; empty and redacted content are not separators.
    var displayUnits: [AgentContentBlock] {
        let known = Set(activities.map(\.id))
        var seenTools: Set<String> = []
        return blocks.filter { block in
            switch block.kind {
            case .activity:
                guard let id = block.activityID, known.contains(id) else { return false }
                return seenTools.insert(id).inserted
            case .text:
                return !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking:
                return !block.redacted && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
    var presentationGroups: [AgentResponseContentGroup] {
        var groups: [AgentResponseContentGroup] = []
        for unit in displayUnits {
            if unit.kind == .activity, groups.last?.isActivity == true {
                groups[groups.count - 1].blocks.append(unit)
            } else {
                groups.append(.init(id: unit.id, blocks: [unit]))
            }
        }
        return groups
    }
    var activityIDs: [String] {
        let known = Set(activities.map(\.id))
        var seen: Set<String> = []
        return blocks.compactMap { block in
            guard let id = block.activityID, known.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }
}
struct AgentResponseContentGroup: Identifiable, Equatable {
    var id: String
    var blocks: [AgentContentBlock]
    var isActivity: Bool { blocks.first?.kind == .activity }
}
struct AgentTranscriptItem: Identifiable, Equatable {
    var id: String
    var user: AgentMessage?
    var response: AgentResponseTurn?
}

/// One visible response spans Pi's assistant/tool continuation turns until the next user input.
/// Content blocks keep their emitted order; tool outputs update rows by ID instead of adding messages.
enum AgentTranscript {
    static func items(messages: [AgentMessage], activities: [AgentActivity]) -> [AgentTranscriptItem] {
        var items: [AgentTranscriptItem] = []
        var linked: Set<String> = []
        for message in messages {
            if message.role == "user" {
                items.append(.init(id: message.id, user: message)); continue
            }
            guard message.role == "assistant" else { continue }
            if items.last?.response == nil { items.append(.init(id: message.id, response: .init(id: message.id))) }
            let itemIndex = items.count - 1
            var response = items[itemIndex].response!
            var content = message.blocks ?? (message.text.isEmpty ? [] : [.init(id: message.id + "-text", index: 0, kind: .text, text: message.text)])
            let associated = activities.filter { $0.afterMessageID == message.id }
            let declared = Set(content.compactMap(\.activityID))
            // Nested/extension tool events may not have an assistant toolCall content block.
            for activity in associated where !declared.contains(activity.id) {
                content.append(.init(id: "activity-" + activity.id, index: content.count, kind: .activity, activityID: activity.id))
            }
            response.blocks += content
            for activity in associated where linked.insert(activity.id).inserted { response.activities.append(activity) }
            response.streaming = response.streaming || message.streaming
            items[itemIndex].response = response
        }
        let unlinked = activities.filter { !linked.contains($0.id) }
        if !unlinked.isEmpty {
            if items.last?.response == nil { items.append(.init(id: "unlinked-" + unlinked[0].id, response: .init(id: "unlinked-" + unlinked[0].id))) }
            let index = items.count - 1
            for activity in unlinked {
                let blockIndex = items[index].response?.blocks.count ?? 0
                items[index].response?.blocks.append(.init(id: "activity-" + activity.id, index: blockIndex, kind: .activity, activityID: activity.id))
                items[index].response?.activities.append(activity)
            }
        }
        return items
    }
}
