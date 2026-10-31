import Foundation

struct OMLXModelStatus: Identifiable, Equatable {
    var id: String
    var state: String?
    var loaded: Bool?
}
struct OMLXStatus: Equatable {
    var reachable = false
    var models: [OMLXModelStatus] = []
    var serverState: String?
    var authenticated: Bool?
    var memoryBytes: Double?
    var detail = "Not configured"
    var checkedAt: Date?
}

/// Read-only telemetry is independent of Pi's inference connection.
/// Optional endpoints may be absent or require a main/admin key; unknown stays unknown.
struct OMLXService {
    var session: URLSession = .shared
    func inspect(_ configuration: OMLXConfiguration, token: String?) async throws -> OMLXStatus {
        let config = try configuration.validated()
        let models: JSONValue
        do { models = try await get(config.apiBase.appendingPathComponent("models"), token: token) }
        catch let error as OMLXHTTPError {
            // A responding server with unavailable/authenticated routes is still reachable.
            return OMLXStatus(reachable: true, authenticated: error.code == 401 || error.code == 403 ? false : nil,
                              detail: "oMLX reachable · " + error.localizedDescription, checkedAt: Date())
        }
        var status = OMLXStatus(reachable: true, models: models["data"].array.compactMap { item in
            guard let id = item["id"].string else { return nil }
            return OMLXModelStatus(id: id, state: item["status"].string, loaded: item["loaded"].boolValue)
        }, detail: "oMLX reachable", checkedAt: Date())
        status.authenticated = true
        // Public status endpoint exposes load state; stats expose memory if authorized.
        if let details = try? await get(config.apiBase.appendingPathComponent("models/status"), token: token) {
            let values = details["models"].array
            for item in values {
                guard let id = item["id"].string ?? item["model_id"].string,
                      let index = status.models.firstIndex(where: { $0.id == id }) else { continue }
                status.models[index].state = item["status"].string ?? item["state"].string
                status.models[index].loaded = item["loaded"].boolValue ?? status.models[index].loaded
            }
        }
        if let health = try? await get(config.serverBase.appendingPathComponent("health"), token: token, acceptedStatuses: [503]) { status.serverState = health["status"].string }
        if let stats = try? await get(config.serverBase.appendingPathComponent("api/status"), token: token) {
            status.memoryBytes = stats["model_memory_used"].number
        }
        if let selected = config.defaultModel {
            if let model = status.models.first(where: { $0.id == selected }) {
                status.detail = "oMLX reachable · \(model.state ?? (model.loaded.map { $0 ? "model loaded" : "model not loaded" } ?? "load state unavailable"))"
            } else { status.detail = "oMLX reachable · selected model unavailable" }
        }
        if status.serverState == "loading" { status.detail = "oMLX reachable · server loading" }
        return status
    }
    private func get(_ url: URL, token: String?, acceptedStatuses: Set<Int> = []) async throws -> JSONValue {
        var request = URLRequest(url: url); request.timeoutInterval = 5
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, ((200..<300).contains(http.statusCode) || acceptedStatuses.contains(http.statusCode)) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OMLXHTTPError(code: code)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
extension JSONValue {
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

private struct OMLXHTTPError: LocalizedError {
    var code: Int
    var errorDescription: String? { code == 401 || code == 403 ? "authentication failed (\(code))" : "status request failed (HTTP \(code))" }
}
