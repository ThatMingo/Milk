import Foundation

enum PreviewState: String { case idle, starting, waiting, loading, running, failed, stopped }
enum PreviewDevice: String, Codable, CaseIterable {
    case desktop = "Desktop", tablet = "Tablet", phone = "Phone"
    var width: CGFloat? { self == .desktop ? nil : self == .tablet ? 768 : 390 }
}
struct PreviewConfiguration: Codable, Equatable {
    enum Kind: String, Codable { case command, staticFiles }
    var kind: Kind = .command
    var command: String
    var directory: URL
    var entryPath: String = ""
    var suggestedURL: URL?
}
struct PreviewMemory: Codable {
    var url: URL?
    var device: PreviewDevice = .desktop
    var configuration: PreviewConfiguration?
    var usesEnteredURL: Bool?
}
enum PreviewURL {
    static func parse(_ value: String, workspace: URL?) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { throw AgentError.message("Enter a valid Preview URL.") }
        let qualified = text.contains("://") ? text : "http://" + text
        guard let url = URL(string: qualified) else { throw AgentError.message("Enter a valid Preview URL.") }
        if url.isFileURL {
            guard let workspace, WorkspaceFileService.isInside(url, root: workspace, resolve: true),
                  ["html", "htm"].contains(url.pathExtension.lowercased()) else { throw AgentError.message("Choose an HTML file inside the current project.") }
            return url
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw AgentError.message("Use an HTTP(S) Preview URL without credentials.") }
        return url
    }
    static func local(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" || host == "::" || host.range(of: #"^127(?:\.[0-9]{1,3}){3}$"#, options: .regularExpression) != nil
    }
    /// Only complete HTTP URLs with an explicit port and loopback/bind host are log candidates.
    static func detected(in output: String) -> [URL] {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/])https?://(?:localhost|[a-zA-Z0-9-]+\.localhost|127(?:\.[0-9]{1,3}){3}|0\.0\.0\.0|\[(?:::1|::)\]):[0-9]{1,5}(?:/[^\s\x1b<>\"'\)\]]*)?(?![A-Za-z0-9:.])"#)
        return regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { match in
            guard let range = Range(match.range, in: clean), var parts = URLComponents(string: String(clean[range])),
                  let port = parts.port, (1...65535).contains(port) else { return nil }
            if parts.host == "0.0.0.0" { parts.host = "127.0.0.1" }
            if parts.host == "[::]" || parts.host == "::" { parts.host = "[::1]" }
            return parts.url
        }
    }
    static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.httpMethod = "HEAD"
        // Never let reachability redirect from loopback to an unrelated host.
        let session = URLSession(configuration: .ephemeral, delegate: PreviewReachabilityDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do { let (_, response) = try await session.data(for: request); return response is HTTPURLResponse }
        catch { return false }
    }
}
private final class PreviewReachabilityDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PreviewDetector {
    static func detect(root: URL, selectedHTML: URL? = nil) throws -> PreviewConfiguration? {
        let fm = FileManager.default
        let package = root.appendingPathComponent("package.json")
        if fm.fileExists(atPath: package.path) {
            let data = try Data(contentsOf: package)
            guard data.count < 2_000_000, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let scripts = json["scripts"] as? [String: String] ?? [:]
            let candidates = scripts.filter {
                $0.value.range(of: #"\b(build|test|lint|check|install)\b"#, options: .regularExpression) == nil &&
                $0.value.range(of: #"\b(vite|next dev|nuxt dev|astro dev|webpack serve|react-scripts start|http-server|parcel)\b"#, options: .regularExpression) != nil
            }
            let script = ["dev", "start", "serve", "develop", "start:dev"].first { !(scripts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                ?? (candidates.count == 1 ? candidates.keys.first : nil)
            if let script {
                let declared = (json["packageManager"] as? String)?.split(separator: "@").first.map(String.init)
                let manager = declared.flatMap { ["npm", "pnpm", "yarn", "bun"].contains($0) ? $0 : nil }
                    ?? ([ ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun") ].first { fm.fileExists(atPath: root.appendingPathComponent($0.0).path) }?.1 ?? "npm")
                return .init(command: manager + " run " + shellQuote(script), directory: root)
            }
            let dependencies = Set((json["dependencies"] as? [String: Any] ?? [:]).keys).union((json["devDependencies"] as? [String: Any] ?? [:]).keys)
            let frameworks: Set<String> = ["vite", "next", "nuxt", "astro", "webpack", "react-scripts", "@angular/core", "@sveltejs/kit", "parcel"]
            // Static projects may use npm for unrelated tooling. Framework source still needs discovery.
            if !dependencies.isDisjoint(with: frameworks) || scripts.values.contains(where: { $0.range(of: #"\b(vite|next|nuxt|astro|webpack|react-scripts|parcel)\b"#, options: .regularExpression) != nil }) { return nil }
        }
        let entry = selectedHTML.flatMap { WorkspaceFileService.isInside($0, root: root, resolve: true) ? $0 : nil }
            ?? ["index.html", "index.htm"].map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        if let entry { return staticConfiguration(root: root, entry: entry) }
        return nil
    }
    static func staticConfiguration(root: URL, entry: URL) -> PreviewConfiguration {
        .init(kind: .staticFiles, command: "Milk static preview", directory: root, entryPath: String(entry.path.dropFirst(root.path.count + 1)))
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
