import Foundation

/// UI cadence is independent of token cadence. Authoritative boundaries flush this
/// buffer before replacing messages; checkpoint/close paths flush accepted text too.
struct AgentStreamBuffer {
    private var deltas: [AgentContentDelta] = []
    private var activityOrder: [String] = []
    private var activities: [String: AgentActivity] = [:]
    mutating func append(_ delta: AgentContentDelta) {
        if let last = deltas.last, last.messageID == delta.messageID, last.index == delta.index, last.kind == delta.kind {
            var merged = delta
            merged.replace = last.replace || delta.replace
            merged.redacted = last.redacted || delta.redacted
            merged.activityID = delta.activityID ?? last.activityID
            merged.text = merged.redacted ? "" : delta.replace ? delta.text : last.text + delta.text
            deltas[deltas.count - 1] = merged
        } else { deltas.append(delta) }
    }
    mutating func append(_ activity: AgentActivity) {
        if activities[activity.id] == nil { activityOrder.append(activity.id) }
        activities[activity.id] = activity
    }
    func apply(to conversation: inout SessionConversation) {
        for delta in deltas {
            if let index = conversation.messages.firstIndex(where: { $0.id == delta.messageID }) { conversation.messages[index].apply(delta) }
        }
        for id in activityOrder {
            guard let activity = activities[id] else { continue }
            if let index = conversation.activities.firstIndex(where: { $0.id == id }) { conversation.activities[index] = activity }
            else { conversation.activities.append(activity) }
        }
    }
}
