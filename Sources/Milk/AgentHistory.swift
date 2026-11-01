import Foundation

/// Complete native history is built away from the visible conversation, then committed once.
struct AgentHistory {
    var messages: [AgentMessage] = []
    var activities: [AgentActivity] = []
    var error: String? = nil

    func reconcile(with cached: SessionConversation) -> SessionConversation {
        let metric = ChatRenderMetrics.begin()
        defer { ChatRenderMetrics.end("history.reconcile", metric) }
        var result = cached
        if let error { result.error = error }
        var used: Set<String> = []
        var remapped: [String: String] = [:]
        // Prefer native identity; old caches need ordered, exact-content matching once.
        let bySource = Dictionary(cached.messages.compactMap { message in
            message.sourceID.map { ($0, message) }
        }, uniquingKeysWith: { first, _ in first })
        var searchStart = 0
        result.messages = messages.map { native in
            var message = native
            var match = native.sourceID.flatMap { bySource[$0] }
            if match == nil {
                if let index = cached.messages.indices.dropFirst(searchStart).first(where: {
                    let old = cached.messages[$0]
                    return !used.contains(old.id) && (old.sourceID == nil || native.sourceID == nil)
                        && old.role == native.role && old.text == native.text
                        && Self.sameContent(old, native)
                }) {
                    match = cached.messages[index]; searchStart = index + 1
                }
            }
            if let match, used.insert(match.id).inserted {
                message.id = match.id
                message.blocks = native.blocks?.map { block in
                    var block = block
                    block.id = match.blocks?.first(where: { $0.index == block.index })?.id ?? "\(message.id)-block-\(block.index)"
                    return block
                }
            }
            message.blocks = message.blocks?.map { block in
                var block = block
                block.activityID = block.activityID.map { AgentActivity.transcriptID($0, messageID: message.id) }
                return block
            }
            remapped[native.id] = message.id
            return message
        }
        let cachedActivities = Dictionary(cached.activities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.activities = activities.map { native in
            var activity = native
            activity.afterMessageID = native.afterMessageID.flatMap { remapped[$0] }
            activity.id = AgentActivity.transcriptID(native.id, messageID: activity.afterMessageID)
            if let old = cachedActivities[activity.id] ?? cachedActivities[native.id], old.afterMessageID == activity.afterMessageID {
                activity.started = old.started; activity.duration = old.duration
            }
            return activity
        }
        // Preview is Milk-owned live activity, outside Pi's authoritative history.
        let nativeActivityIDs = Set(result.activities.map(\.id))
        result.activities += cached.activities.filter { $0.id.hasPrefix("preview-") && !nativeActivityIDs.contains($0.id) }
        if let anchor = result.scrollAnchor, !result.messages.contains(where: { $0.id == anchor || anchor.hasPrefix($0.id + "-") }), anchor != "tail" {
            result.scrollAnchor = nil; result.scrollAnchorOwner = nil
        }
        return result
    }
    private static func sameContent(_ old: AgentMessage, _ native: AgentMessage) -> Bool {
        if old.blocks == nil { return native.blocks?.allSatisfy { $0.kind == .text } != false }
        let before = old.blocks ?? [], after = native.blocks ?? []
        guard before.count == after.count else { return false }
        return zip(before, after).allSatisfy { lhs, rhs in
            let sameTool = lhs.activityID == rhs.activityID || rhs.activityID.map { lhs.activityID == AgentActivity.transcriptID($0, messageID: old.id) } == true
            return lhs.index == rhs.index && lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.redacted == rhs.redacted && sameTool
        }
    }
}
