import Foundation

/// Pi message/content decoding shared by live RPC and saved conversation reconstruction.
/// It deliberately discards opaque/redacted thinking payloads and retains visible block order.
struct PiMessageDecoder {
    private(set) var currentMessageID: String?
    private var partial: AgentMessage?
    mutating func consume(_ record: JSONValue) -> [AgentEvent] {
        switch record["type"].string {
        case "turn_start": currentMessageID = nil; partial = nil
        case "message_start":
            let value = record["message"]
            guard ["user", "assistant"].contains(value["role"].string ?? "") else { return [] }
            let message = decode(value, id: UUID().uuidString, streaming: value["role"].string == "assistant")
            currentMessageID = message.id; partial = message
            return [.message(message)]
        case "message_update":
            guard let id = currentMessageID, partial?.role == "assistant" else { return [] }
            let event = record["assistantMessageEvent"], type = event["type"].string ?? ""
            let kind: AgentContentBlock.Kind
            if type.hasPrefix("thinking_") { kind = .thinking }
            else if type.hasPrefix("text_") { kind = .text }
            else if type == "toolcall_start" || type == "toolcall_end" { kind = .activity }
            else { return [] }
            let end = type.hasSuffix("_end")
            let text = event[end ? "content" : "delta"].string ?? ""
            let delta = AgentContentDelta(messageID: id, index: Int(event["contentIndex"].number ?? 0), kind: kind,
                                          text: kind == .activity ? "" : text, replace: end, finished: end,
                                          redacted: event["redacted"].bool,
                                          activityID: event["id"].string ?? event["toolCall"]["id"].string)
            partial?.apply(delta)
            return [.contentDelta(delta)]
        case "message_end":
            guard let id = currentMessageID, ["user", "assistant"].contains(record["message"]["role"].string ?? "") else { return [] }
            let message = decode(record["message"], id: id, streaming: false)
            partial = message
            var events: [AgentEvent] = [.message(message)]
            if record["message"]["stopReason"].string == "error" { events.append(.failure(record["message"]["errorMessage"].string ?? "Provider request failed.")) }
            return events
        case "turn_end":
            if var message = partial, message.streaming {
                message.streaming = false
                if let blocks = message.blocks { message.blocks = blocks.map { var block = $0; block.streaming = false; return block } }
                partial = message; return [.message(message)]
            }
        default: break
        }
        return []
    }
    mutating func restore(_ value: JSONValue, id: String) -> AgentMessage {
        let message = decode(value, id: id, streaming: false)
        currentMessageID = id; partial = message; return message
    }
    private func decode(_ value: JSONValue, id: String, streaming: Bool) -> AgentMessage {
        let role = value["role"].string ?? ""
        guard role == "assistant" else { return .init(id: id, role: role, text: value["content"].text) }
        let blocks: [AgentContentBlock] = value["content"].array.enumerated().compactMap { index, item in
            let blockID = "\(id)-block-\(index)"
            switch item["type"].string {
            case "text": return .init(id: blockID, index: index, kind: .text, text: item["text"].string ?? "", streaming: streaming)
            case "thinking": return .init(id: blockID, index: index, kind: .thinking, text: item["redacted"].bool ? "" : item["thinking"].string ?? "", streaming: streaming, redacted: item["redacted"].bool)
            case "toolCall": return .init(id: blockID, index: index, kind: .activity, activityID: item["id"].string)
            default: return nil
            }
        }
        return .init(id: id, role: role, text: blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"), streaming: streaming, blocks: blocks)
    }
}
