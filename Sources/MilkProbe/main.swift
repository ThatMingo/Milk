import Foundation
import MilkCore

actor ProbeEvents {
    var text = ""
    var settled = false
    var bridge = false
    var deltas = 0
    var failure: String?
    func receive(_ event: PiEvent) {
        switch event {
        case .record(let record):
            if record["type"].string == "message_update", record["assistantMessageEvent"]["type"].string == "text_delta" { text += record["assistantMessageEvent"]["delta"].string ?? ""; deltas += 1 }
            if record["type"].string == "agent_settled" { settled = true }
            if record["type"].string == "extension_ui_request", record["statusKey"].string == "milk.bridge" { bridge = true }
        case .failed(let error): failure = error
        default: break
        }
    }
    func reset() { text = ""; deltas = 0; settled = false }
    func snapshot() -> (String, Bool, Bool, Int, String?) { (text, settled, bridge, deltas, failure) }
}

@main struct MilkProbe {
    static func wait(_ events: ProbeEvents, forDeltas: Bool = false) async throws {
        for _ in 0..<2400 {
            let state = await events.snapshot()
            if let error = state.4 { throw MilkError.message(error) }
            if forDeltas ? state.3 >= 4 : state.1 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MilkError.message("Live Pi validation timed out")
    }
    static func launch(_ installation: PiInstallation, folder: URL, id: UUID, file: String? = nil) async throws -> (PiClient, ProbeEvents, Task<Void, Never>) {
        let client = PiClient(), events = ProbeEvents()
        let reader = Task { for await event in client.events { await events.receive(event) } }
        var environment = installation.environment; environment["MILK_AGENT_MODE"] = "approval"
        var args = ["--mode", "rpc", "--extension", PiDiscovery.companionURL.path]
        args += file.map { ["--session", $0] } ?? ["--session-id", id.uuidString.lowercased()]
        try await client.start(.init(executable: installation.executable, arguments: args, directory: folder, environment: environment))
        _ = try await client.request("get_state")
        _ = try await client.request("prompt", fields: ["message": .string("/milk-bridge")])
        for _ in 0..<100 { if await events.snapshot().2 { return (client, events, reader) }; try await Task.sleep(for: .milliseconds(50)) }
        await client.shutdown(); throw MilkError.message("Companion handshake failed")
    }
    static func main() async throws {
        guard CommandLine.arguments.contains("--live") else { print("Use --live to explicitly validate the installed Pi/provider stack"); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MilkLive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let installation = try await PiDiscovery.discover()
        let firstID = UUID(), secondID = UUID()
        let (first, firstEvents, firstReader) = try await launch(installation, folder: folder, id: firstID)
        do {
            let state = try await first.request("get_state")
            print("Pi \(installation.version) provider=\(state["model"]["provider"].string ?? "?") model=\(state["model"]["id"].string ?? "?")")
            await firstEvents.reset()
            _ = try await first.request("prompt", fields: ["message": .string("Reply exactly MILK_LIVE_OK. Do not use tools.")])
            try await wait(firstEvents)
            let firstResult = await firstEvents.snapshot()
            guard firstResult.0.contains("MILK_LIVE_OK") else { throw MilkError.message("Unexpected live response") }
            print("PASS streamed actual response; deltas=\(firstResult.3)")
            let saved = try await first.request("get_state")
            guard let file = saved["sessionFile"].string else { throw MilkError.message("Pi did not persist the session") }
            let (second, secondEvents, secondReader) = try await launch(installation, folder: folder, id: secondID)
            do {
                let secondState = try await second.request("get_state")
                let history = try await second.request("get_messages")
                guard secondState["sessionId"] != saved["sessionId"], history["messages"].array.isEmpty else { throw MilkError.message("Sessions were not independent") }
                print("PASS second process has independent identity and empty history")
                await secondEvents.reset()
                _ = try await second.request("prompt", fields: ["message": .string("Write the numbers from 1 to 10000, one per line, without tools or explanation.")])
                try await wait(secondEvents, forDeltas: true)
                try await second.stop()
                guard try await second.request("get_state")["isStreaming"].bool == false else { throw MilkError.message("Abort did not reach idle") }
                print("PASS abort real generation and reach idle")
                await second.shutdown(); secondReader.cancel()
            } catch { await second.shutdown(); secondReader.cancel(); throw error }
            await first.shutdown(); firstReader.cancel()
            let (resumed, resumedEvents, resumedReader) = try await launch(installation, folder: folder, id: firstID, file: file)
            do {
                let history = try await resumed.request("get_messages")
                guard history["messages"].description.contains("MILK_LIVE_OK") else { throw MilkError.message("Resume lost history") }
                await resumedEvents.reset()
                _ = try await resumed.request("prompt", fields: ["message": .string("Reply exactly MILK_RESUMED_OK. Do not use tools.")])
                try await wait(resumedEvents)
                guard await resumedEvents.snapshot().0.contains("MILK_RESUMED_OK") else { throw MilkError.message("Resumed prompt failed") }
                print("PASS exact saved-session resume and follow-up")
                await resumed.shutdown(); resumedReader.cancel()
            } catch { await resumed.shutdown(); resumedReader.cancel(); throw error }
            print("PASS live stack validation completed; fixture workspace: \(folder.path)")
        } catch { await first.shutdown(); firstReader.cancel(); throw error }
    }
}
