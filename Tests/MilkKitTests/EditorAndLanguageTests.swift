import AppKit
import Testing
import MilkCore
@testable import MilkKit

@Test func lspFramesSplitAtEveryByte() throws {
    let payload = Data(#"{"jsonrpc":"2.0","method":"🥛"}"#.utf8)
    let wire = Data("Content-Length: \(payload.count)\r\n\r\n".utf8) + payload
    for split in 0...wire.count {
        var framer = LSPFramer()
        let first = try framer.append(Data(wire.prefix(split))), second = try framer.append(Data(wire.dropFirst(split)))
        #expect((first + second).first?["method"].string == "🥛")
    }
}
@Test func jsonTreeSitterWorksWithoutLanguageServer() async {
    let tokens = await HighlightingService().tokens(text: #"{"name":"Milk","count":42,"ready":true}"#, extension: "json")
    #expect(tokens.contains { $0.kind == .number })
    #expect(tokens.contains { $0.kind == .keyword })
    #expect(tokens.contains { $0.kind == .string })
}
@Test @MainActor func editorDetectsExternalConflictAndRejectsRacingSave() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MilkEditorTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("example.swift"), files = FileService()
    try Data("baseline\n".utf8).write(to: file)
    let editor = EditorController(files: files); try await editor.open(file); try await editor.open(file)
    #expect(editor.documents.count == 1)
    let document = try #require(editor.current)
    document.content.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 8), with: "manual"); document.didEdit()
    try Data("external\n".utf8).write(to: file)
    await document.synchronize()
    #expect(document.dirty && document.externalVersion == "external\n")
    await #expect(throws: MilkError.self) { try await document.save() }
    try await document.keepBuffer(); try await document.save()
    #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("manual"))
    #expect(!document.dirty)
}
@Test func previewProviderRouting() {
    let provider = NativePreviewProvider()
    #expect(provider.kind(for: URL(string: "http://localhost:3000")!) == .web)
    #expect(provider.kind(for: URL(fileURLWithPath: "/tmp/file.pdf")) == .pdf)
    #expect(provider.kind(for: URL(fileURLWithPath: "/tmp/file.svg")) == .web)
    #expect(provider.kind(for: URL(fileURLWithPath: "/tmp/file.md")) == .markdown)
}
@Test @MainActor func sharedDocumentUndoRedoRestoresDirtyState() throws {
    let doc = try DocumentBuffer(url: URL(fileURLWithPath: "/tmp/test.swift"), data: Data("original".utf8), files: FileService())
    doc.undo.groupsByEvent = false; doc.undo.beginUndoGrouping()
    doc.content.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 8), with: "edited")
    doc.didEdit(); doc.undo.endUndoGrouping()
    #expect(doc.canUndo && doc.dirty)
    doc.undo.undo(); #expect(doc.text == "original" && !doc.dirty && doc.canRedo)
    doc.undo.redo(); #expect(doc.text == "edited" && doc.dirty)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["MILK_TEST_LSP"] == "1"))
func sourceKitInitialization() async throws {
    let client = LanguageServerClient()
    try await client.start(executable: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"), workspace: FileManager.default.temporaryDirectory)
    var initialized = false
    for await event in client.events { if event["result"]["capabilities"] != .null { initialized = true; break } }
    await client.shutdown(); #expect(initialized)
}
@Test @MainActor func lineNumberRulerDoesNotPaintOverSourceText() throws {
    let view = NSTextView(usingTextLayoutManager: true); view.string = "let answer = 42\n"
    let ruler = LineNumberRuler(textView: view); ruler.frame = NSRect(x: 0, y: 0, width: 48, height: 100)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 300, height: 100).fill()
    ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 300, height: 100))
    let outside = try #require(bitmap.colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
    #expect(outside.redComponent > 0.99 && outside.greenComponent < 0.01)
}
