import Foundation
import SwiftUI
import Combine
import MilkExtensionKit

@MainActor
public final class OMLXStatsTest: MilkExtension {
    private var model: StatsModel?

    public override func activate(context: any ExtensionContext) async throws {
        let model = StatsModel(context: context)
        self.model = model
        try context.contributions.sidebar(.init(
            id: "omlx-stats",
            title: "oMLX Stats",
            systemImage: "gauge.with.dots.needle.67percent"
        ) { _ in AnyView(StatsView(model: model)) })
        try context.contributions.service(.init(id: "poll") { _ in
            while !Task.isCancelled {
                await model.refresh()
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
    }

    public override func deactivate() async { model = nil }
}

private struct Snapshot {
    var model = "No model loaded"
    var generation: Double?
    var prefill: Double?
    var requests: Int?
    var prompt: Int?
    var completion: Int?
    var cached: Int?
    var cacheEfficiency: Double?
    var active: Int?
    var waiting: Int?
    var memory: Int64?
    var memoryMax: Int64?
    var loaded: Int?
    var available: Int?
}

@MainActor
private final class StatsModel: ObservableObject {
    let context: any ExtensionContext
    @Published var endpoint = "http://127.0.0.1:8000"
    @Published var token = ""
    @Published var status = "Checking"
    @Published var error = ""
    @Published var stats = Snapshot()
    @Published var refreshing = false

    init(context: any ExtensionContext) {
        self.context = context
        if let data = try? context.storage.read("endpoint.txt"),
           let saved = String(data: data, encoding: .utf8), !saved.isEmpty {
            endpoint = saved
        }
    }

    func save() {
        do {
            try context.storage.write(Data(endpoint.utf8), to: "endpoint.txt")
            if !token.isEmpty { try context.secrets?.write(token, for: "api-key"); token = "" }
            self.error = "Saved"
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func clearKey() {
        do { try context.secrets?.write(nil, for: "api-key"); self.error = "Inference key removed"; Task { await refresh() } }
        catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        // /health is intentionally unauthenticated. Never require an admin key.
        let health: [String: Any]
        do {
            health = try await get("/health")
        } catch {
            status = "Offline"
            stats = Snapshot()
            self.error = "Cannot reach oMLX: " + error.localizedDescription
            return
        }

        let pool = health["engine_pool"] as? [String: Any] ?? [:]
        let defaultModel = health["default_model"] as? String
        let fallbackModel = (defaultModel?.isEmpty == false) ? defaultModel! : "Not specified"
        let fallback = Snapshot(
            model: fallbackModel,
            generation: nil, prefill: nil,
            requests: nil, prompt: nil, completion: nil,
            cached: nil, cacheEfficiency: nil,
            active: nil, waiting: nil,
            memory: int64(pool["current_model_memory"]),
            memoryMax: int64(pool["final_ceiling"]),
            loaded: integer(pool["loaded_count"]),
            available: integer(pool["model_count"])
        )

        // /api/status is a read-only statusline endpoint. A normal inference
        // sub-key is accepted; no /admin/api/* URL is ever requested.
        do {
            let data = try await get("/api/status")
            let loaded = data["loaded_models"] as? [String] ?? []
            let model = loaded.count == 1
                ? loaded[0]
                : (loaded.isEmpty ? fallbackModel : loaded.joined(separator: ", "))
            stats = Snapshot(
                model: model,
                generation: number(data["avg_generation_tps"]),
                prefill: number(data["avg_prefill_tps"]),
                requests: integer(data["total_requests"]),
                prompt: integer(data["total_prompt_tokens"]),
                completion: integer(data["total_completion_tokens"]),
                cached: integer(data["total_cached_tokens"]),
                cacheEfficiency: number(data["cache_efficiency"]),
                active: integer(data["active_requests"]),
                waiting: integer(data["waiting_requests"]),
                memory: int64(data["model_memory_used"]) ?? fallback.memory,
                memoryMax: int64(data["model_memory_max"]) ?? fallback.memoryMax,
                loaded: integer(data["models_loaded"]) ?? fallback.loaded,
                available: integer(data["models_discovered"]) ?? fallback.available
            )
            status = "Live"
            self.error = ""
        } catch {
            stats = fallback
            status = (health["status"] as? String) == "loading" ? "Loading" : "Basic"
            if error.localizedDescription.contains("401") {
                let saved = (try? context.secrets?.read("api-key")) ?? ""
                self.error = saved.isEmpty
                    ? "Connected in basic mode. oMLX requires a standard inference key to show request, speed and cache statistics. An admin key is never needed."
                    : "Connected in basic mode. The standard inference key was rejected (401). Check the key, or clear it to continue with keyless health monitoring."
            } else {
                self.error = "Connected in basic mode. Extended stats unavailable: " + error.localizedDescription
            }
        }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        guard let network = context.network else {
            throw StatsError.message("Network capability unavailable")
        }
        let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: cleaned),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty else {
            throw StatsError.message("Invalid oMLX endpoint")
        }
        guard let url = URL(string: path, relativeTo: URL(string: scheme + "://" + host + (components.port.map { ":" + String($0) } ?? "")))?.absoluteURL else {
            throw StatsError.message("Invalid oMLX URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if path == "/api/status",
           let key = try context.secrets?.read("api-key"), !key.isEmpty {
            // Refuse to send even a normal inference key in cleartext to a
            // non-loopback server. Remote endpoints require HTTPS.
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
            guard scheme == "https" || local else {
                throw StatsError.message("Use HTTPS for remote authenticated connections")
            }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await network.data(for: request)
        let accepted = (200..<300).contains(response.statusCode)
            || (path == "/health" && response.statusCode == 503)
        guard accepted else {
            throw StatsError.message("HTTP " + String(response.statusCode))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatsError.message("Invalid JSON")
        }
        return json
    }
}

private enum StatsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
private func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

@MainActor
private struct StatsView: View {
    @ObservedObject var model: StatsModel
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(ExtensionTheme.accent)
                    Text("oMLX Stats").font(.headline)
                    Spacer()
                    ExtensionStatusBadge(model.status)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Loaded / default model").font(.caption).foregroundStyle(ExtensionTheme.secondaryText)
                    Text(model.stats.model).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(ExtensionTheme.surface, in: RoundedRectangle(cornerRadius: 10))

                LazyVGrid(columns: columns, spacing: 8) {
                    tile("Generation", speed(model.stats.generation), "tok/s")
                    tile("Prefill", speed(model.stats.prefill), "tok/s")
                    tile("Requests", count(model.stats.requests), nil)
                    tile("Cache", percent(model.stats.cacheEfficiency), nil)
                    tile("Loaded models", count(model.stats.loaded), nil)
                    tile("Available models", count(model.stats.available), nil)
                }

                rows([
                    ("Prompt tokens", count(model.stats.prompt)),
                    ("Completion tokens", count(model.stats.completion)),
                    ("Cached tokens", count(model.stats.cached)),
                    ("Active requests", count(model.stats.active)),
                    ("Waiting requests", count(model.stats.waiting)),
                    ("Model memory", bytes(model.stats.memory)),
                    ("Memory ceiling", bytes(model.stats.memoryMax))
                ])

                DisclosureGroup("Connection · optional") {
                    VStack(spacing: 8) {
                        TextField("http://127.0.0.1:8000", text: $model.endpoint).textFieldStyle(.roundedBorder)
                        SecureField("Optional inference key (never admin)", text: $model.token).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save") { model.save() }.buttonStyle(ExtensionButtonStyle())
                            Button("Clear inference key") { model.clearKey() }.buttonStyle(ExtensionButtonStyle())
                            Button("Refresh") { Task { await model.refresh() } }.buttonStyle(ExtensionButtonStyle()).disabled(model.refreshing)
                        }
                        Text("Basic health and model memory work without a key. For throughput, requests and cache statistics, oMLX may require your normal inference key. Never enter an admin key.")
                            .font(.caption).foregroundStyle(ExtensionTheme.secondaryText)
                    }.padding(.top, 8)
                }

                if !model.error.isEmpty {
                    Text(model.error).font(.caption).foregroundStyle(ExtensionTheme.secondaryText).textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh() }
    }

    private func tile(_ title: String, _ value: String, _ suffix: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(ExtensionTheme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.semibold))
                if let suffix, value != "—" { Text(suffix).font(.caption2).foregroundStyle(ExtensionTheme.secondaryText) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
         .background(ExtensionTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func rows(_ values: [(String, String)]) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                HStack { Text(item.0).foregroundStyle(ExtensionTheme.secondaryText); Spacer(); Text(item.1).textSelection(.enabled) }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 8).background(ExtensionTheme.surface)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func speed(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    private func count(_ value: Int?) -> String { value.map { String($0) } ?? "—" }
    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        let p = value <= 1 ? value * 100 : value
        return String(format: "%.1f%%", p)
    }
    private func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}