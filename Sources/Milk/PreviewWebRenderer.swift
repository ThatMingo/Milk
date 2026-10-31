import SwiftUI
import WebKit

/// Owns the WKWebView across SwiftUI visibility/layout changes. No process lifecycle lives here.
@MainActor final class PreviewWebRenderer: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var pendingURL: URL?
    private var stopped = false
    private var activeNavigation: WKNavigation?
    private var loadTimeout: DispatchWorkItem?
    var navigationTimeout: TimeInterval = 20
    var workspace: URL?
    var onLoading: (() -> Void)?
    var onFinished: ((URL) -> Void)?
    var onFailure: ((String) -> Void)?
    var webView: WKWebView {
        if let view { return view }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let value = WKWebView(frame: .zero, configuration: config)
        value.navigationDelegate = self; value.allowsBackForwardNavigationGestures = false
        view = value
        if let pendingURL, !stopped { performLoad(pendingURL) }
        return value
    }
    func load(_ url: URL) { stopped = false; pendingURL = url; if view != nil { performLoad(url) } }
    private func performLoad(_ url: URL) {
        armTimeout()
        if url.isFileURL, let workspace { activeNavigation = view?.loadFileURL(url, allowingReadAccessTo: workspace) }
        else { activeNavigation = view?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: navigationTimeout)) }
    }
    func reload() {
        stopped = false
        if let view, view.url != nil { armTimeout(); activeNavigation = view.reload() }
        else if let pendingURL { load(pendingURL) }
    }
    func stop() { stopped = true; loadTimeout?.cancel(); view?.stopLoading() }
    private func armTimeout() {
        loadTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.view?.stopLoading()
            self.onFailure?("Preview took too long to load. Check the URL or reload to try again.")
        }
        loadTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + navigationTimeout, execute: work)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped else { return }
        activeNavigation = navigation; armTimeout(); onLoading?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, navigation === activeNavigation, let url = webView.url else { return }
        loadTimeout?.cancel(); pendingURL = url; onFinished?(url)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation) }
    private func failed(_ error: Error, navigation: WKNavigation?) {
        guard !stopped, navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        loadTimeout?.cancel(); onFailure?("Preview could not load: " + error.localizedDescription)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadTimeout?.cancel()
        if !stopped { onFailure?("Web content stopped. Reload Preview to reconnect.") }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !stopped, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let allowed = ["http", "https", "about", "blob"].contains(url.scheme ?? "") || (url.isFileURL && workspace.map { WorkspaceFileService.isInside(url, root: $0, resolve: true) } == true)
        if allowed, navigationAction.targetFrame == nil { load(url); decisionHandler(.cancel) }
        else { decisionHandler(allowed ? .allow : .cancel) }
    }
}

struct ProjectWebView: NSViewRepresentable {
    let renderer: PreviewWebRenderer
    func makeNSView(context: Context) -> WKWebView {
        let view = renderer.webView
        view.removeFromSuperview() // Reparent the workspace's retained page when the grid changes.
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { }
    // Dismantling a panel deliberately doesn't stop its page or server.
}
