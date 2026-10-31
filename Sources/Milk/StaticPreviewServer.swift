import Foundation
import Network
import UniformTypeIdentifiers
import Darwin

/// A subprocess of Milk, using the same owned process-group lifecycle as framework servers.
/// Serves only regular, nonhidden project files on IPv4 loopback; no listing, writes or shelling out.
enum StaticPreviewServer {
    static func run(root: URL) -> Never {
        do {
            let queue = DispatchQueue(label: "dev.milk.preview.http", attributes: .concurrent)
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port { FileHandle.standardOutput.write(Data("Milk Preview http://127.0.0.1:\(port.rawValue)\n".utf8)) }
                case .failed(let error): FileHandle.standardError.write(Data("Static Preview: \(error)\n".utf8)); exit(1)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                let timeout = DispatchWorkItem { connection.cancel() }
                queue.asyncAfter(deadline: .now() + 10, execute: timeout)
                receive(connection, data: Data(), root: root.resolvingSymlinksInPath(), timeout: timeout)
            }
            listener.start(queue: queue)
            withExtendedLifetime(listener) { dispatchMain() }
        } catch { FileHandle.standardError.write(Data("Static Preview: \(error)\n".utf8)); exit(1) }
    }
    private static func receive(_ connection: NWConnection, data: Data, root: URL, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
            var request = data; request.append(chunk ?? Data())
            guard request.count <= 65536, error == nil else { connection.cancel(); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(connection, request: String(decoding: request, as: UTF8.self), root: root, timeout: timeout)
            } else if complete { connection.cancel() }
            else { receive(connection, data: request, root: root, timeout: timeout) }
        }
    }
    static func resource(for target: String, root: URL) -> URL? {
        guard let path = target.split(separator: "?", maxSplits: 1).first.map(String.init)?.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        var file = root.appendingPathComponent(String(path.dropFirst())).resolvingSymlinksInPath()
        guard WorkspaceFileService.isInside(file, root: root, resolve: true) else { return nil }
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { file.appendPathComponent("index.html") }
        guard WorkspaceFileService.isInside(file, root: root, resolve: true),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
    private static func respond(_ connection: NWConnection, request: String, root: URL, timeout: DispatchWorkItem) {
        let words = request.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
        let method = words.first ?? ""
        let allowed = method == "GET" || method == "HEAD"
        let file = words.count == 3 && allowed ? resource(for: words[1], root: root) : nil
        let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        let status = !allowed ? "405 Method Not Allowed" : data != nil ? "200 OK" : "404 Not Found"
        let body = data ?? Data(status.utf8)
        let mime: String
        switch file?.pathExtension.lowercased() {
        case "js", "mjs": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html", "htm": mime = "text/html; charset=utf-8"
        case "json", "map": mime = "application/json"
        case "svg": mime = "image/svg+xml"
        case "wasm": mime = "application/wasm"
        default: mime = file.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? "text/plain"
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        if method != "HEAD" { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in timeout.cancel(); connection.cancel() })
    }
}
