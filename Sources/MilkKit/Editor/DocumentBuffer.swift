import AppKit
import Observation
import MilkCore

@MainActor @Observable public final class DocumentBuffer: Identifiable {
    public let id = UUID()
    public var url: URL
    public let content = NSTextContentStorage()
    public let undo = UndoManager()
    public private(set) var revision = 0
    public private(set) var dirty = false
    public private(set) var externalVersion: String?
    public private(set) var missingOnDisk = false
    public private(set) var baseline: Data
    @ObservationIgnored private var lastText: String
    public var selection = NSRange(location: 0, length: 0)
    public var text: String { _ = revision; return content.textStorage?.string ?? "" }
    public var canUndo: Bool { _ = revision; return undo.canUndo }
    public var canRedo: Bool { _ = revision; return undo.canRedo }
    private let files: FileService
    @ObservationIgnored public var changed: (@MainActor () -> Void)?
    public init(url: URL, data: Data, files: FileService) throws {
        guard let string = String(data: data, encoding: .utf8) else { throw MilkError.message("This file is binary or is not UTF-8") }
        self.url = url; self.baseline = data; self.files = files; self.lastText = string
        content.textStorage = NSTextStorage(string: string)
    }
    public func didEdit() {
        let current = content.textStorage?.string ?? ""
        if current != lastText {
            let previous = lastText
            undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.replaceText(previous) } }
            undo.setActionName("Edit")
            lastText = current
        }
        revision += 1; dirty = Data(current.utf8) != baseline; changed?()
    }
    private func replaceText(_ text: String) {
        content.textStorage?.replaceCharacters(in: NSRange(location: 0, length: content.textStorage?.length ?? 0), with: text)
        didEdit()
    }
    public func replaceFromEditor(_ text: String) { replaceText(text) }
    public func save() async throws {
        guard externalVersion == nil, !missingOnDisk else { throw MilkError.message("Resolve the external change before saving") }
        let bytes = Data(text.utf8); try await files.save(bytes, at: url, expected: baseline)
        baseline = bytes; dirty = Data(text.utf8) != baseline
    }
    public func synchronize() async {
        guard let disk = try? await files.read(url) else { missingOnDisk = true; return }
        missingOnDisk = false
        guard disk != baseline else { return }
        if dirty { externalVersion = String(data: disk, encoding: .utf8) ?? "[Binary content]" }
        else if let updated = String(data: disk, encoding: .utf8) {
            content.textStorage?.replaceCharacters(in: NSRange(location: 0, length: content.textStorage?.length ?? 0), with: updated)
            baseline = disk; lastText = updated; revision += 1; undo.removeAllActions(); changed?()
        }
    }
    public func reloadDisk() async throws {
        let disk = try await files.read(url)
        guard let text = String(data: disk, encoding: .utf8) else { throw MilkError.message("Disk version is not UTF-8") }
        content.textStorage?.replaceCharacters(in: NSRange(location: 0, length: content.textStorage?.length ?? 0), with: text)
        baseline = disk; lastText = text; externalVersion = nil; missingOnDisk = false; dirty = false; revision += 1; undo.removeAllActions(); changed?()
    }
    public func keepBuffer() async throws {
        // Explicit user decision establishes a fresh disk baseline; save still rechecks it.
        baseline = try await files.read(url); externalVersion = nil; dirty = Data(text.utf8) != baseline
    }
}

@MainActor @Observable public final class EditorController {
    public private(set) var documents: [DocumentBuffer] = []
    public var selected: UUID?
    public var secondary: UUID?
    public var split = false
    public let files: FileService
    public let languages = LanguageServiceManager()
    public var languageStatus = "Language server not connected"
    @ObservationIgnored private var swiftServer: LanguageServerClient?
    @ObservationIgnored private var languageEvents: Task<Void, Never>?
    @ObservationIgnored private var languageWrite: Task<Void, Never>?
    public init(files: FileService) { self.files = files }
    public var current: DocumentBuffer? { documents.first { $0.id == selected } }
    public func open(_ url: URL) async throws {
        if let existing = documents.first(where: { $0.url == url }) { selected = existing.id; return }
        let document = try DocumentBuffer(url: url, data: await files.read(url), files: files)
        document.changed = { [weak self, weak document] in if let document { self?.documentChanged(document) } }
        documents.append(document); selected = document.id
        if let swiftServer, url.pathExtension == "swift" { try await openLanguageDocument(document, client: swiftServer) }
    }
    public func saveAll() async throws { for doc in documents where doc.dirty { try await doc.save() } }
    public func synchronize() async { for doc in documents { await doc.synchronize() } }
    public func connectSwift(workspace: URL) async throws {
        let executable = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp")
        let server = try await languages.connect(language: "swift", executable: executable, workspace: workspace); swiftServer = server
        languageEvents?.cancel()
        languageEvents = Task { [weak self] in
            for await event in server.events {
                if event["method"].string == "textDocument/publishDiagnostics" { self?.languageStatus = "\(event["params"]["diagnostics"].array.count) diagnostics" }
                else if event["result"] != .null { self?.languageStatus = String(event["result"].description.prefix(1000)) }
            }
        }
        for doc in documents where doc.url.pathExtension == "swift" { try await openLanguageDocument(doc, client: server) }
        languageStatus = "SourceKit-LSP connected"
    }
    private func openLanguageDocument(_ document: DocumentBuffer, client: LanguageServerClient) async throws {
        try await client.notify("textDocument/didOpen", params: .object(["textDocument": .object([
            "uri": .string(document.url.absoluteString), "languageId": .string("swift"), "version": .number(Double(document.revision)), "text": .string(document.text)
        ])]))
    }
    private func documentChanged(_ document: DocumentBuffer) {
        guard let swiftServer, document.url.pathExtension == "swift" else { return }
        let uri = document.url.absoluteString, version = document.revision, text = document.text
        let previous = languageWrite
        languageWrite = Task {
            await previous?.value; guard !Task.isCancelled else { return }
            try? await swiftServer.notify("textDocument/didChange", params: .object([
                "textDocument": .object(["uri": .string(uri), "version": .number(Double(version))]),
                "contentChanges": .array([.object(["text": .string(text)])])
            ]))
        }
    }
    public func hover() async throws {
        guard let current, let swiftServer else { throw MilkError.message("Connect a language server and open a Swift file first") }
        let position = LanguageServerClient.position(in: current.text, utf16Offset: current.selection.location)
        _ = try await swiftServer.request("textDocument/hover", params: .object([
            "textDocument": .object(["uri": .string(current.url.absoluteString)]),
            "position": .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))])
        ]))
    }
    public func reset() {
        documents.removeAll(); selected = nil; secondary = nil; swiftServer = nil
        languageEvents?.cancel(); languageEvents = nil; languageWrite?.cancel(); languageWrite = nil; languageStatus = "Language server not connected"
    }
    public func close(_ doc: DocumentBuffer) throws {
        guard !doc.dirty else { throw MilkError.message("Save or resolve unsaved edits before closing this file") }
        documents.removeAll { $0.id == doc.id }; if selected == doc.id { selected = documents.last?.id }
    }
}
