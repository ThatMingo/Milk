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
}

@MainActor
private final class StatsModel: ObservableObject {
    let context: any ExtensionContext
    @Published var endpoint = "http://127.0.0.1:8000"
    @Published var token = ""
    @Published var status = "Not checked"
    @Published var error = ""
    @Published var stats = Snapshot()
    @Published var refreshing = false

    init(context: any ExtensionContext) {
        self.context = context
        if let data = try? context.storage.read("endpoint.txt"),
           let data, let saved = String(data: data, encoding: .utf8), !saved.isEmpty {
            endpoint = saved
        }
    }

    func save() {
        do {
            try context.storage.write(Data(endpoint.utf8), to: "endpoint.txt")
            if !token.isEmpty { try context.secrets?.write(token, for: "api-key"); token = "" }
            error = "Saved"
            Task { await refresh() }
        } catch { error = error.localizedDescription }
    }

    func clearKey() {
        do { try context.secrets?.write(nil, for: "api-key"); error = "API key removed" }
        catch { error = error.localizedDescription }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let publicStatus = try await get("/api/status")
            let loaded = publicStatus["loaded_models"] as? [String] ?? []
            var current: String? = loaded.count == 1 ? loaded.first : nil

            if let activity = try? await get("/admin/api/activity"),
               let active = activity["active_models"] as? [String: Any],
               let rows = active["models"] as? [[String: Any]] {
                current = rows.first(where: { row in
                    let generating = (row["generating"] as? [Any])?.isEmpty == false
                    let prefilling = (row["prefilling"] as? [Any])?.isEmpty == false
                    let activities = (row["activities"] as? [Any])?.isEmpty == false
                    return generating || prefilling || activities
                }).flatMap { ($0["id"] ?? $0["model_id"]) as? String } ?? current
            }
            if current == nil { current = loaded.first }

            guard let current else {
                stats = Snapshot()
                status = "Connected"
                error = ""
                return
            }

            do {
                let admin = try await get("/admin/api/stats", query: [
                    URLQueryItem(name: "scope", value: "session"),
                    URLQueryItem(name: "model", value: current)
                ])
                let active = admin["active_models"] as? [String: Any]
                let rows = active?["models"] as? [[String: Any]] ?? []
                let row = rows.first { (($0["id"] ?? $0["model_id"]) as? String) == current }
                stats = Snapshot(
                    model: current,
                    generation: number(admin["avg_generation_tps"]),
                    prefill: number(admin["avg_prefill_tps"]),
                    requests: integer(admin["total_requests"]),
                    prompt: integer(admin["total_prompt_tokens"]),
                    completion: integer(admin["total_completion_tokens"]),
                    cached: integer(admin["total_cached_tokens"]),
                    cacheEfficiency: number(admin["cache_efficiency"]),
                    active: integer(row?["active_requests"]) ?? integer(active?["total_active_requests"]),
                    waiting: integer(row?["waiting_requests"]) ?? integer(active?["total_waiting_requests"]),
                    memory: int64(active?["model_memory_used"]),
                    memoryMax: int64(active?["model_memory_max"])
                )
                error = ""
            } catch {
                stats = Snapshot(
                    model: current,
                    generation: number(publicStatus["avg_generation_tps"]),
                    prefill: number(publicStatus["avg_prefill_tps"]),
                    requests: integer(publicStatus["total_requests"]),
                    prompt: integer(publicStatus["total_prompt_tokens"]),
                    completion: integer(publicStatus["total_completion_tokens"]),
                    cached: integer(publicStatus["total_cached_tokens"]),
                    cacheEfficiency: number(publicStatus["cache_efficiency"]),
                    active: integer(publicStatus["active_requests"]),
                    waiting: integer(publicStatus["waiting_requests"]),
                    memory: int64(publicStatus["model_memory_used"]),
                    memoryMax: int64(publicStatus["model_memory_max"])
                )
                error = "Admin stats unavailable. Add the main oMLX API key below for full per-model stats."
            }
            status = "Connected"
        } catch {
            status = "Offline"
            stats = Snapshot()
            self.error = error.localizedDescription
        }
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let network = context.network else { throw StatsError.message("Network capability unavailable") }
        guard var components = URLComponents(string: endpoint), components.host != nil else { throw StatsError.message("Invalid oMLX endpoint") }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw StatsError.message("Invalid oMLX URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = try context.secrets?.read("api-key"), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await network.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw StatsError.message("HTTP \(response.statusCode)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StatsError.message("Invalid JSON") }
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
                    Text("Current model").font(.caption).foregroundStyle(ExtensionTheme.secondaryText)
                    Text(model.stats.model).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(ExtensionTheme.surface, in: RoundedRectangle(cornerRadius: 10))

                LazyVGrid(columns: columns, spacing: 8) {
                    tile("Generation", speed(model.stats.generation), "tok/s")
                    tile("Prefill", speed(model.stats.prefill), "tok/s")
                    tile("Requests", count(model.stats.requests), nil)
                    tile("Cache", percent(model.stats.cacheEfficiency), nil)
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

                DisclosureGroup("Connection") {
                    VStack(spacing: 8) {
                        TextField("http://127.0.0.1:8000", text: $model.endpoint).textFieldStyle(.roundedBorder)
                        SecureField("Main oMLX API key", text: $model.token).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save") { model.save() }.buttonStyle(ExtensionButtonStyle())
                            Button("Clear key") { model.clearKey() }.buttonStyle(ExtensionButtonStyle())
                            Button("Refresh") { Task { await model.refresh() } }.buttonStyle(ExtensionButtonStyle()).disabled(model.refreshing)
                        }
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