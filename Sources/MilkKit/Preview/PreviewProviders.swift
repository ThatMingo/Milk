import SwiftUI
import WebKit
import PDFKit
import Markdown
import MilkCore

public enum PreviewKind: String, Sendable { case web, markdown, image, pdf, text }
public protocol PreviewProviding: Sendable { var id: String { get }; func kind(for url: URL) -> PreviewKind? }
public struct NativePreviewProvider: PreviewProviding {
    public let id = "milk.native"
    public init() {}
    public func kind(for url: URL) -> PreviewKind? {
        if ["http", "https"].contains(url.scheme) { return .web }
        return switch url.pathExtension.lowercased() {
        case "html", "htm", "svg": .web
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp": .image
        case "pdf": .pdf
        default: .text
        }
    }
}
public actor PreviewRegistry {
    private var providers: [any PreviewProviding] = [NativePreviewProvider()]
    public init() {}
    public func register(_ provider: any PreviewProviding) { providers.insert(provider, at: 0) }
    public func kind(for url: URL) -> PreviewKind { providers.lazy.compactMap { $0.kind(for: url) }.first ?? .text }
}
public actor MarkdownService {
    public init() {}
    public func blocks(_ source: String) -> [String] {
        let document = Markdown.Document(parsing: source)
        return document.children.map { $0.format() }
    }
}
public struct PreviewPane: View {
    public let url: URL
    @State private var kind = PreviewKind.text
    @State private var text = ""
    @State private var image: NSImage?
    private let registry = PreviewRegistry()
    public init(url: URL) { self.url = url }
    public var body: some View {
        Group {
            switch kind {
            case .web: WebPreview(url: url)
            case .pdf: PDFPreview(url: url)
            case .image: if let image { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1000) } } else { ContentUnavailableView("Image unavailable", systemImage: "photo") }
            case .markdown: ScrollView { Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            case .text: ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            }
        }.task(id: url) {
            kind = await registry.kind(for: url)
            if [.text, .markdown].contains(kind) {
                text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "Preview unavailable" }.value
                if kind == .markdown { text = await MarkdownService().blocks(text).joined(separator: "\n\n") }
                if url.pathExtension == "json", let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data), let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { text = String(decoding: formatted, as: UTF8.self) }
            }
            if kind == .image { image = NSImage(contentsOf: url) }
        }
    }
}
private struct WebPreview: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator; return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(url, in: view)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        @MainActor private var requested: URL?
        @MainActor func load(_ url: URL, in view: WKWebView) {
            guard requested != url else { return }; requested = url
            Task { @MainActor in
                if url.isFileURL {
                    do {
                        let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "MilkStaticPreview", encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#)
                        guard requested == url else { return }
                        if let rules { view.configuration.userContentController.add(rules) }
                        view.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                    } catch { view.loadHTMLString("<p>Unable to apply static preview security rules.</p>", baseURL: nil) }
                } else {
                    view.configuration.userContentController.removeAllContentRuleLists()
                    view.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
                    view.load(URLRequest(url: url))
                }
            }
        }
        @MainActor func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            decisionHandler(["file", "http", "https", "about"].contains(url.scheme) ? .allow : .cancel)
        }
    }
}
private struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}
