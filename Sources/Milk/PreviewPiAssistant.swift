import Foundation

/// An ephemeral Pi inspection, separate from user conversations. Built-in reads only, no MCP,
/// third-party extensions, writes or bash. Returned commands always pass the normal startup gate.
@MainActor enum PreviewPiAssistant {
    static func discover(root: URL, model: AgentModel? = nil, backend: AgentBackend) async throws -> PreviewConfiguration {
        var messages: [String: AgentMessage] = [:]
        var settled = false, failure: String?
        backend.onEvent = { event in
            switch event {
            case .message(let value): messages[value.id] = value
            case .contentDelta(let delta): messages[delta.messageID]?.apply(delta)
            case .settled: settled = true
            case .failure(let text): failure = text
            case .approval(let request): try? backend.respond(request, value: nil, confirmed: nil, cancelled: true)
            default: break
            }
        }
        defer { backend.onEvent = nil; backend.shutdown() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 90_000_000_000); if !Task.isCancelled { failure = "Pi Preview inspection timed out."; backend.shutdown() } }
        defer { timeout.cancel() }
        try await backend.start(workspace: root, session: .init(id: -1, title: "Preview inspection"))
        if let model { try await backend.setModel(model) }
        try await backend.send(.init(text: """
        Inspect this project to determine its foreground local web development server command and correct working directory. Read files only. Do not run commands, start a server, install dependencies, edit files or change configuration. Prefer existing project dev/start/serve scripts. Do not daemonize. Reply ONLY with a JSON object: {"command":"exact shell command", "directory":"workspace-relative directory or .", "url":"optional local HTTP URL if known"}. If no web preview is possible return {"error":"short reason"}. Milk will separately obtain permission and own process startup. Workspace: \(root.path)
        """), intent: .prompt)
        while !settled && failure == nil {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let failure { throw AgentError.message(failure) }
        let answers = messages.values.filter { $0.role == "assistant" }.map(\.text)
        for answer in answers.reversed() {
            if let config = try? parse(answer, root: root) { return config }
        }
        throw AgentError.message("Pi could not identify a Preview command. Enter a running project URL or add a project dev/start script.")
    }
    static func parse(_ answer: String, root: URL) throws -> PreviewConfiguration {
        guard let first = answer.firstIndex(of: "{"), let last = answer.lastIndex(of: "}"), first <= last,
              let data = String(answer[first...last]).data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let command = json["command"], !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = json["directory"] else { throw AgentError.message("Pi did not return a Preview configuration.") }
        let directory = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
        guard WorkspaceFileService.isInside(directory, root: root, resolve: true), (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AgentError.message("Pi suggested a directory outside this project.") }
        let url = json["url"].flatMap { try? PreviewURL.parse($0, workspace: root) }.flatMap { PreviewURL.local($0) ? $0 : nil }
        return .init(command: command, directory: directory, suggestedURL: url)
    }
}
