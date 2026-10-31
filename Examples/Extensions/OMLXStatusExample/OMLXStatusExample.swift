import Foundation
import SwiftUI
import Combine
import MilkExtensionKit

/// External example only. Nothing in Milk core depends on this type or its endpoint.
@MainActor public final class OMLXStatusExample: MilkExtension {
    private var model: StatusModel?
    public override func activate(context: any ExtensionContext) async throws {
        let model=try StatusModel(context:context); self.model=model
        let screen=ExtensionViewContribution(id:"status",title:"oMLX",systemImage:"server.rack") { _ in AnyView(StatusScreen(model:model)) }
        try context.contributions.sidebar(screen)
        try context.contributions.panel(.init(id:"status",title:"oMLX Status",systemImage:"server.rack") { _ in AnyView(StatusScreen(model:model)) })
        try context.contributions.settings(.init(id:"connection",title:"oMLX Status",systemImage:"server.rack") { _ in AnyView(StatusSettings(model:model)) })
        try context.contributions.status(.init(id:"connection",title:"oMLX",systemImage:"server.rack",priority:0) { _ in AnyView(StatusLabel(model:model)) })
        try context.contributions.command(.init(name:"omlx",summary:"Open oMLX Status") { _ in try context.focusSidebar("status") })
        try context.contributions.view(at:.chatToolbar,.init(id:"connection",title:"oMLX",systemImage:"server.rack") { _ in AnyView(StatusToolbar(model:model)) })
        try context.contributions.piTool(.init(id:"status",description:"Read the last observed oMLX connection state; unknown telemetry is not invented.",parameters:Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8),requiredCapabilities:[.network]) { _,_ in model.summary })
        try context.contributions.prompt(id:"status-help",text:"Use the oMLX Status tool for observed connection information. Available model IDs do not imply that a model is loaded. Never invent telemetry.")
        try context.contributions.service(.init(id:"poll") { _ in
            while !Task.isCancelled {
                await model.refresh()
                try await Task.sleep(nanoseconds:UInt64(max(5,min(300,model.config.interval)))*1_000_000_000)
            }
        })
    }
    public override func deactivate() async { model=nil } // Milk revokes registrations/tasks regardless.
}
private struct Configuration: Codable {
    var endpoint="http://127.0.0.1:8000"
    var interval=15
    var showStatus=false
}
@MainActor private final class StatusModel: ObservableObject {
    let context: any ExtensionContext
    @Published var config: Configuration
    @Published var connection="Not checked"
    @Published var models: [String] = []
    @Published var loaded: [String] = []
    @Published var loadStateAvailable=false
    @Published var memoryBytes: Double?
    @Published var problem=""
    @Published var checking=false
    var summary: String { "oMLX · \(connection)" + (loaded.isEmpty ? "":" · "+loaded.joined(separator:", ")) }
    init(context: any ExtensionContext) throws {
        self.context=context
        config=try context.storage.read("settings.json").flatMap { try? JSONDecoder().decode(Configuration.self,from:$0) } ?? Configuration()
    }
    @discardableResult func save(token: String?, replaceToken: Bool) -> Bool {
        do {
            guard let url=URL(string:config.endpoint), ["http","https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else { throw ExampleError.message("Enter an HTTP(S) endpoint without credentials in the URL.") }
            config.interval=max(5,min(300,config.interval))
            if replaceToken { try context.secrets?.write(token?.isEmpty == true ? nil:token,for:"api-token") }
            try context.storage.write(JSONEncoder().encode(config),to:"settings.json"); problem="Saved"; return true
        } catch { problem=error.localizedDescription; return false }
    }
    func get(_ url: URL) async throws -> [String:Any] {
        guard let network=context.network else { throw ExampleError.message("Network capability is unavailable.") }
        var request=URLRequest(url:url); request.timeoutInterval=5
        if let token=try context.secrets?.read("api-token"), !token.isEmpty { request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization") }
        let (data,response)=try await network.data(for:request)
        guard (200..<300).contains(response.statusCode) else { throw ExampleError.message("HTTP \(response.statusCode)") }
        guard let json=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ExampleError.message("Expected a JSON object.") }
        return json
    }
    func refresh() async {
        guard !checking, let endpoint=URL(string:config.endpoint), ["http","https"].contains(endpoint.scheme), endpoint.host != nil else { return }
        checking=true; defer { checking=false }
        do {
            let api=endpoint.path.hasSuffix("/v1") ? endpoint:endpoint.appendingPathComponent("v1")
            let response=try await get(api.appendingPathComponent("models"))
            try Task.checkCancellation()
            let values=response["data"] as? [[String:Any]] ?? []
            models=values.compactMap { $0["id"] as? String }
            loaded=values.filter { $0["loaded"] as? Bool == true }.compactMap { $0["id"] as? String }
            loadStateAvailable=values.contains { $0["loaded"] as? Bool != nil }
            // Optional fields are only displayed when actually reported by this API.
            if let status=try? await get(api.appendingPathComponent("models/status")), let values=status["models"] as? [[String:Any]] {
                loaded=values.filter { $0["loaded"] as? Bool == true }.compactMap { ($0["id"] ?? $0["model_id"]) as? String }
                loadStateAvailable=values.contains { $0["loaded"] as? Bool != nil }
            }
            let base=endpoint.path.hasSuffix("/v1") ? endpoint.deletingLastPathComponent():endpoint
            if let status=try? await get(base.appendingPathComponent("api/status")) { let bytes=(status["model_memory_used"] as? NSNumber)?.doubleValue; memoryBytes=bytes.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int64.max) ? $0:nil } } else { memoryBytes=nil }
            try Task.checkCancellation(); connection="Connected"
        } catch is CancellationError {} catch { connection=error.localizedDescription; models=[]; loaded=[]; loadStateAvailable=false; memoryBytes=nil }
    }
}
private enum ExampleError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let message)=self { return message }; return nil } }
@MainActor private struct StatusScreen: View {
    @ObservedObject var model: StatusModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text("oMLX").font(.title2)
                ExtensionStatusBadge(model.connection)
                Text("Loaded: "+(model.loadStateAvailable ? (model.loaded.isEmpty ? "None reported":model.loaded.joined(separator:", ")):"Not reported by API"))
                if let memory=model.memoryBytes { Text("Model memory: "+ByteCountFormatter.string(fromByteCount:Int64(memory),countStyle:.memory)) }
                Text("Available models").font(.headline)
                ForEach(model.models,id:\.self) { Text($0) }
                if model.models.isEmpty { Text("No model information available").foregroundStyle(ExtensionTheme.secondaryText) }
                Button("Refresh") { Task { await model.refresh() } }.buttonStyle(ExtensionButtonStyle()).disabled(model.checking)
                Text("Configure endpoint, token, interval and optional status item in Settings → oMLX Status.").font(.caption).foregroundStyle(ExtensionTheme.secondaryText)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
@MainActor private struct StatusSettings: View {
    @ObservedObject var model: StatusModel
    @State private var token=""
    @State private var replaceToken=false
    var body: some View {
        ExtensionSettingsSection("oMLX Status") {
            ExtensionSettingsRow("Endpoint") { TextField("http://host:port",text:$model.config.endpoint).textFieldStyle(.roundedBorder) }
            ExtensionSettingsRow("Token") { SecureField("Unchanged",text:Binding(get:{token},set:{token=$0;replaceToken=true})).textFieldStyle(.roundedBorder) }
            ExtensionSettingsRow("Remove stored token") { Button("Remove") { token=""; replaceToken=true } }
            ExtensionSettingsRow("Refresh interval") { Stepper("\(model.config.interval) seconds",value:$model.config.interval,in:5...300) }
            ExtensionSettingsRow("Show status bar item") { Toggle("Show status",isOn:$model.config.showStatus).labelsHidden() }
            ExtensionSettingsRow("Save connection") { Button("Save") { if model.save(token:token,replaceToken:replaceToken) { token=""; replaceToken=false; Task { await model.refresh() } } }; Text(model.problem) }
        }
    }
}
@MainActor private struct StatusLabel: View {
    @ObservedObject var model: StatusModel
    var body: some View { if model.config.showStatus { Text(model.summary).font(.caption).lineLimit(1) } }
}
@MainActor private struct StatusToolbar: View {
    @ObservedObject var model: StatusModel
    var body: some View { Button { try? model.context.focusSidebar("status") } label: { Image(systemName:"server.rack") }.help(model.summary).buttonStyle(ExtensionButtonStyle()) }
}
