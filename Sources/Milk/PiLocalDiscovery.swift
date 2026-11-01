import Foundation

struct PiLocalInspection {
    var models: [PiModelCapabilities]
    var detail: String { "Connection successful · \(models.count) models" }
}
/// Configuration/discovery only. No inference, health routes, telemetry or polling.
struct PiLocalDiscovery {
    var session: URLSession = .shared
    func inspect(_ configuration: PiLocalConfiguration, token: String?) async throws -> PiLocalInspection {
        let config = try configuration.validated()
        var request = URLRequest(url: config.apiBase.appendingPathComponent("models")); request.timeoutInterval = 5
        if config.authentication == .apiKey {
            guard let token = try token.map(AgentProviderCredentials.normalized), !token.isEmpty else { throw AgentError.message("Enter or save the Local API key first.") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Never forward credentials to a redirected origin.
        let (data, response) = try await session.data(for: request, delegate: NoProviderRedirect())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AgentError.message(code == 401 || code == 403 ? "Local authentication failed (HTTP \(code))." : "Local model discovery failed (HTTP \(code)).")
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array = root["data"] else { throw AgentError.message("The endpoint did not return an OpenAI-compatible model list.") }
        var seen = Set<String>()
        let models = root["data"].array.compactMap { item -> PiModelCapabilities? in
            guard let id = item["id"].string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            func positive(_ key: String) -> Int? {
                guard let v = item[key].number, v.isFinite, v > 0, v.rounded() == v, v < Double(Int.max) else { return nil }; return Int(v)
            }
            // OpenAI /models has no standard capability schema. Only explicit effective
            // fields are consumed; vendor/theoretical fields are deliberately not inferred.
            return .init(id: id, contextWindow: positive("effective_context_window") ?? positive("context_window"), maxTokens: positive("effective_max_tokens") ?? positive("max_tokens"), reasoning: item["reasoning"].boolValue,
                         images: item["input"].array.isEmpty ? nil : item["input"].array.compactMap(\.string).contains("image"))
        }
        return .init(models: models)
    }
}
private final class NoProviderRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
extension JSONValue { var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil } }
