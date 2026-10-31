import XCTest
@testable import Milk

final class ChatPresentationTests: XCTestCase {
    private func record(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }
    func testThinkingDeltaOrderingAuthoritativeEndAndRedaction() throws {
        var decoder = PiMessageDecoder(), messages: [AgentMessage] = []
        func accept(_ events: [AgentEvent]) {
            for event in events {
                switch event {
                case .message(let message):
                    if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message } else { messages.append(message) }
                case .contentDelta(let delta): if let i = messages.firstIndex(where: { $0.id == delta.messageID }) { messages[i].apply(delta) }
                default: break
                }
            }
        }
        let stream = [
            #"{"type":"turn_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"Visible thinking"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_end","contentIndex":0,"content":"Authoritative thinking"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Before tool"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","contentIndex":2,"id":"tool-1","toolName":"read"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":3,"delta":"Later thinking"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":4,"delta":"After tool"}}"#
        ]
        for json in stream { accept(decoder.consume(try record(json))) }
        let live = try XCTUnwrap(messages.last)
        XCTAssertEqual(live.blocks?.map(\.kind), [.thinking, .text, .activity, .thinking, .text])
        XCTAssertEqual(live.blocks?.first?.text, "Authoritative thinking")
        XCTAssertEqual(live.blocks?[2].activityID, "tool-1")
        let redacted = try record(#"{"role":"assistant","content":[{"type":"thinking","thinking":"must not display","thinkingSignature":"opaque encrypted payload","redacted":true},{"type":"text","text":"Public answer"}]}"#)
        let restored = decoder.restore(redacted, id: "redacted")
        XCTAssertFalse(restored.blocks!.contains(where: \.visibleThinking))
        let saved = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertFalse(saved.contains("must not display")); XCTAssertFalse(saved.contains("opaque encrypted payload"))
    }
    func testOneResponseWithSeparateActivityGroupsAcrossContinuationsAndHistory() throws {
        var decoder = PiMessageDecoder()
        let first = decoder.restore(try record(#"{"role":"assistant","content":[{"type":"thinking","thinking":"First"},{"type":"text","text":"Before"},{"type":"toolCall","id":"tool-1","name":"read","arguments":{"path":"file"}}]}"#), id: "assistant-1")
        let second = decoder.restore(try record(#"{"role":"assistant","content":[{"type":"text","text":"Between"},{"type":"thinking","thinking":"Second"},{"type":"toolCall","id":"tool-2","name":"bash","arguments":{"command":"echo test"}},{"type":"text","text":"After"}]}"#), id: "assistant-2")
        let activities = [AgentActivity(id: "tool-1", kind: "Read", detail: "file", afterMessageID: first.id), AgentActivity(id: "tool-2", kind: "Command", detail: "echo test", afterMessageID: second.id)]
        let user = AgentMessage(id: "user", role: "user", text: "Task")
        let transcript = AgentTranscript.items(messages: [user, first, second], activities: activities)
        XCTAssertEqual(transcript.count, 2)
        let response = try XCTUnwrap(transcript.last?.response)
        XCTAssertEqual(response.activityIDs, ["tool-1", "tool-2"])
        XCTAssertEqual(response.presentationGroups.filter(\.isActivity).map { $0.blocks.count }, [1, 1])
        XCTAssertEqual(response.blocks.map(\.kind), [.thinking, .text, .activity, .text, .thinking, .activity, .text])
        XCTAssertEqual(response.blocks.filter { $0.kind == .text }.map(\.text), ["Before", "Between", "After"])
        let restored = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode([user, first, second]))
        XCTAssertEqual(AgentTranscript.items(messages: restored, activities: activities), transcript)
        let next = AgentMessage(id: "follow-up", role: "user", text: "Next task")
        XCTAssertEqual(AgentTranscript.items(messages: [user, first, second, next, .init(id: "next-answer", role: "assistant", text: "Next answer")], activities: activities).count, 4)
    }
    func testConsecutiveActivityGroupsSplitAtTextAndThinking() {
        func response(_ kinds: [AgentContentBlock.Kind]) -> AgentResponseTurn {
            var result = AgentResponseTurn(id: "response")
            for (index, kind) in kinds.enumerated() {
                let id = "item-\(index)"
                result.blocks.append(.init(id: id, index: index, kind: kind, text: kind == .activity ? "" : "Content", activityID: kind == .activity ? id : nil))
                if kind == .activity { result.activities.append(.init(id: id, kind: "Command", detail: id, output: "Attached output")) }
            }
            return result
        }
        let text = response([.activity, .activity, .text, .activity, .activity])
        XCTAssertEqual(text.presentationGroups.map { $0.blocks.count }, [2, 1, 2])
        XCTAssertEqual(text.presentationGroups.map { $0.blocks[0].kind }, [.activity, .text, .activity])
        let thinking = response([.activity, .thinking, .activity])
        XCTAssertEqual(thinking.presentationGroups.map { $0.blocks.count }, [1, 1, 1])
        XCTAssertEqual(thinking.presentationGroups.map { $0.blocks[0].kind }, [.activity, .thinking, .activity])
        XCTAssertEqual(thinking.activities.map(\.output), ["Attached output", "Attached output"])
        // Redacted/internal content is not a visible separator.
        var hidden = thinking
        hidden.blocks[1].redacted = true
        hidden.blocks[1].text = ""
        XCTAssertEqual(hidden.presentationGroups.filter(\.isActivity).map { $0.blocks.count }, [2])
    }
    func testRPCMessageAndToolLifecycleBoundariesDoNotSplitVisibleActivityRuns() throws {
        var decoder = PiMessageDecoder()
        var messages = [AgentMessage(id: "user", role: "user", text: "Task")]
        var activities: [AgentActivity] = []
        func consume(_ raw: JSONValue) {
            for event in decoder.consume(raw) {
                if case .message(let message) = event {
                    if let i = messages.firstIndex(where: { $0.id == message.id }) { messages[i] = message }
                    else { messages.append(message) }
                }
            }
            // Pi's lifecycle reducer updates one operation by toolCallId, never a Chat message.
            if let id = raw["toolCallId"].string {
                if let i = activities.firstIndex(where: { $0.id == id }) {
                    activities[i].output = raw["result"]["content"].text
                    if raw["type"].string == "tool_execution_end" { activities[i].status = .completed }
                } else {
                    activities.append(.init(id: id, kind: "Command", detail: id, afterMessageID: decoder.currentMessageID))
                }
            }
        }
        for (index, id) in ["A", "B", "C", "D", "E", "F"].enumerated() {
            consume(try record(#"{"type":"turn_start"}"#))
            // Each tool lives in a separate assistant RPC message with empty/internal blocks.
            let message: [String: Any] = ["role": "assistant", "content": [
                ["type": "text", "text": " \n"],
                ["type": "thinking", "thinking": "", "redacted": true],
                ["type": "toolCall", "id": id, "name": "bash", "arguments": ["command": "echo " + id]]
            ]]
            for type in ["message_start", "message_end"] {
                let data = try JSONSerialization.data(withJSONObject: ["type": type, "message": message])
                consume(try JSONDecoder().decode(JSONValue.self, from: data))
            }
            for type in ["tool_execution_start", "tool_execution_update", "tool_execution_end"] {
                let data = try JSONSerialization.data(withJSONObject: ["type": type, "toolCallId": id, "result": ["content": [["type": "text", "text": "output " + id]]]])
                consume(try JSONDecoder().decode(JSONValue.self, from: data))
            }
            consume(try record(#"{"type":"message_start","message":{"role":"toolResult","content":[{"type":"text","text":"internal result"}]}}"#))
            consume(try record(#"{"type":"turn_end"}"#))
            if index == 2 || index == 5 {
                let visible = try record(#"{"role":"assistant","content":[{"type":"text","text":"Visible assistant text"}]}"#)
                messages.append(decoder.restore(visible, id: "text-\(index)"))
            }
        }
        let transcript = AgentTranscript.items(messages: messages, activities: activities)
        XCTAssertEqual(transcript.count, 2) // One user and one logical Pi response.
        let response = try XCTUnwrap(transcript.last?.response)
        XCTAssertEqual(response.presentationGroups.map { $0.blocks.count }, [3, 1, 3, 1])
        XCTAssertEqual(response.presentationGroups.map { $0.blocks[0].kind }, [.activity, .text, .activity, .text])
        XCTAssertEqual(response.activities.count, 6)
        XCTAssertEqual(response.activities.map(\.output), ["A", "B", "C", "D", "E", "F"].map { "output " + $0 })
        let restored = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(messages))
        XCTAssertEqual(AgentTranscript.items(messages: restored, activities: activities), transcript)
    }
    func testOldMessageSnapshotsRemainDecodableAndGrouped() throws {
        let old = Data(#"[{"id":"a","role":"assistant","text":"Old answer","streaming":false},{"id":"b","role":"assistant","text":"Continuation","streaming":false}]"#.utf8)
        let messages = try JSONDecoder().decode([AgentMessage].self, from: old)
        XCTAssertNil(messages[0].blocks)
        XCTAssertEqual(AgentTranscript.items(messages: messages, activities: []).count, 1)
    }
    @MainActor func testComposerGrowsForNewlinesAndWrappingButStopsAtSixRows() {
        let compact = ComposerInputMetrics.height(text: "One line", width: 500)
        let multiline = ComposerInputMetrics.height(text: "One\nTwo\nThree\nFour", width: 500)
        XCTAssertGreaterThan(multiline, compact)
        XCTAssertGreaterThan(ComposerInputMetrics.height(text: String(repeating: "wrapped words ", count: 15), width: 330), compact)
        XCTAssertEqual(ComposerInputMetrics.height(text: String(repeating: "row\n", count: 30), width: 330), ComposerInputMetrics.maximumHeight)
        XCTAssertGreaterThan(ComposerInputMetrics.height(text: "row\n", width: 500), compact)
    }
}
