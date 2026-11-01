import SwiftUI

extension PiAdapter: AgentSettingsProviding {
    var settingsSections: [AgentSettingsSection] { [.init(id: "pi.configuration", title: "Pi configuration")] }
    func settingsView(section: String, agent: AgentService) -> AnyView {
        AnyView(PiSettingsContent(agent: agent, adapter: self))
    }
    var providerProfileIdentity: PiProviderProfileIdentity {
        get throws { try PiProfileIdentitySupport.identity(runtime: runtime, installations: installations, mode: configuration().runtime) }
    }
    var providerDirectory: URL {
        get throws {
            if let installations { return try installations.selectedProfile().directory }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(runtime.environmentOverrides) { _, new in new }
            return PiProfile.existing(environment: environment).directory
        }
    }
    func saveProviderSettings(_ value: PiProviderConfiguration, token: String?, agent: AgentService) throws {
        let token = try token.map(AgentProviderCredentials.normalized)
        _ = try value.local.validated(requireModel: value.provider == .local)
        try agent.applyAgentSettings {
            let profile = try providerProfileIdentity.rawValue
            let directory = try providerDirectory
            let file = directory.appendingPathComponent("models.json")
            let original = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            let originalKey = token == nil ? nil : try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: value.local.endpoint, profile: profile)
            var keyChanged = false
            do {
                var environment: [String: String] = [:]
                // Validate/translate the entire Pi configuration before changing Keychain.
                try PiProviderSupport.apply(value, directory: directory, environment: &environment, credential: token, profile: profile)
                if let token {
                    try AgentProviderCredentials.save(token, agent: .pi, provider: "local", endpoint: value.local.endpoint, profile: profile)
                    keyChanged = true
                }
                try value.save(defaults, key: installations?.providerSettingsKey ?? providerProfileIdentity.settingsKey)
            } catch {
                do {
                    if keyChanged { try AgentProviderCredentials.save(originalKey ?? "", agent: .pi, provider: "local", endpoint: value.local.endpoint, profile: profile) }
                    if let original {
                        if (try? Data(contentsOf: file)) != original {
                            try original.write(to: file, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        }
                    } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                } catch { throw AgentError.message("Pi settings could not be restored after a failed save. Original models.json bytes remain in the pre-milk-local backup.") }
                throw error
            }
        }
    }
}

/// Pi owns this schema and draft; the global settings host never interprets fields.
@MainActor final class PiSettingsModel: ObservableObject {
    @Published var configuration = PiProviderConfiguration()
    @Published var endpoint = ""
    @Published var model = ""
    @Published var token = ""
    @Published var replaceToken = false
    @Published var context = ""
    @Published var output = ""
    @Published var reasoning = "auto"
    @Published var images = "auto"
    @Published var result = ""
    @Published var busy = false
    @Published var tokenStored = false
    @Published var loadFailed = false
    private(set) var profileIdentity: String?
    let adapter: PiAdapter
    let agent: AgentService
    init(agent: AgentService, adapter: PiAdapter) {
        self.agent = agent; self.adapter = adapter
        do {
            profileIdentity = try adapter.providerProfileIdentity.rawValue
            configuration = try adapter.providerConfiguration()
            endpoint = configuration.local.endpoint.absoluteString
            model = configuration.local.selectedModel ?? ""
            loadModel(); refreshCredentialState()
        } catch { result = error.localizedDescription; loadFailed = true }
    }
    func refreshCredentialState() {
        guard let profileIdentity, let url = URL(string: endpoint) else { tokenStored = false; return }
        do { tokenStored = try AgentProviderCredentials.exists(agent: .pi, provider: "local", endpoint: url, profile: profileIdentity) }
        catch { tokenStored = false; result = error.localizedDescription }
    }
    func importLegacyCredential() {
        do {
            let value = try edited()
            guard let profileIdentity else { return }
            let found = try AgentProviderCredentials.importLegacy(agent: .pi, provider: "local", endpoint: value.local.endpoint, profile: profileIdentity)
            if found { configuration.local.authentication = .apiKey }
            refreshCredentialState()
            result = found ? "Legacy credential imported for this profile. Save Pi Settings to use it." : "No legacy credential found. Paste a new API key."
        } catch { result = error.localizedDescription }
    }
    func endpointChanged() {
        token = ""; replaceToken = false; refreshCredentialState()
        configuration.local.models = configuration.local.models.map { .init(id: $0.id) }
        loadModel(); result = "Endpoint changed. Test Connection to discover this server's models and limits."
    }
    func loadModel() {
        let item = configuration.local.models.first { $0.id == model }
        context = item?.contextOverride.map(String.init) ?? ""
        output = item?.outputOverride.map(String.init) ?? ""
        reasoning = (item?.reasoning ?? item?.reasoningOverride).map { $0 ? "yes" : "no" } ?? "auto"
        images = (item?.images ?? item?.imagesOverride).map { $0 ? "yes" : "no" } ?? "auto"
    }
    func storeModelDraft() throws {
        guard !model.isEmpty else { return }
        func limit(_ raw: String) throws -> Int? {
            let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { return nil }
            guard let number = Int(raw), number > 0 else { throw AgentError.message("Enter a positive token count or leave Auto empty.") }; return number
        }
        var item = configuration.local.models.first { $0.id == model } ?? .init(id: model)
        item.contextOverride = try limit(context); item.outputOverride = try limit(output)
        if item.reasoning == nil { item.reasoningOverride = reasoning == "auto" ? nil : reasoning == "yes" }
        if item.images == nil { item.imagesOverride = images == "auto" ? nil : images == "yes" }
        configuration.local.models.removeAll { $0.id == model }; configuration.local.models.append(item)
    }
    func edited() throws -> PiProviderConfiguration {
        guard let profileIdentity, try adapter.providerProfileIdentity.rawValue == profileIdentity else {
            throw AgentError.message("Pi profile changed. Reopen its settings before applying this draft.")
        }
        if configuration.provider == .configured { return configuration }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AgentError.message("Invalid Local endpoint.") }
        try storeModelDraft()
        var value = configuration; value.local.endpoint = url; value.local.selectedModel = model.isEmpty ? nil : model
        _ = try value.local.validated()
        return value
    }
    func testConnection(discovery: PiLocalDiscovery = .init()) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let value = try edited()
                let draftToken = token, draftReplacement = replaceToken
                let key = value.local.authentication == .apiKey ? (replaceToken ? token : try AgentProviderCredentials.token(agent: .pi, provider: "local", endpoint: value.local.endpoint, profile: profileIdentity)) : nil
                let status = try await discovery.inspect(value.local, token: key)
                guard (try adapter.providerProfileIdentity.rawValue) == profileIdentity, URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) == value.local.endpoint,
                      configuration.provider == value.provider, configuration.local.authentication == value.local.authentication,
                      token == draftToken, replaceToken == draftReplacement else {
                    result = "Settings changed while testing. Test Connection again."; return
                }
                // Replace server metadata on refresh; preserve explicit per-model declarations.
                let old = value.local.models
                configuration.local.models = status.models.map { discovered in
                    var item = discovered
                    if let previous = old.first(where: { $0.id == item.id }) {
                        item.contextOverride = previous.contextOverride; item.outputOverride = previous.outputOverride
                        item.reasoningOverride = previous.reasoningOverride; item.imagesOverride = previous.imagesOverride
                    }
                    return item
                }
                if !configuration.local.models.contains(where: { $0.id == model }), !model.isEmpty {
                    // Retain unavailable selections and overrides; do not silently select another model.
                    var unavailable = old.first(where: { $0.id == model }) ?? .init(id: model)
                    unavailable.contextWindow = nil; unavailable.maxTokens = nil
                    unavailable.reasoning = nil; unavailable.images = nil
                    configuration.local.models.append(unavailable)
                    result = status.detail + " · selected model is not currently advertised"
                } else { result = status.detail }
                loadModel()
            } catch { result = "Connection failed: \(error.localizedDescription)" }
        }
    }
    func save() {
        do {
            let value = try edited()
            try adapter.saveProviderSettings(value, token: replaceToken ? token : nil, agent: agent)
            configuration = value; token = ""; replaceToken = false; refreshCredentialState()
            result = "Saved. Idle Pi runtimes reconnect with this configuration."
        } catch { result = error.localizedDescription }
    }
}

struct PiSettingsContent: View {
    @ObservedObject var agent: AgentService
    @StateObject private var model: PiSettingsModel
    init(agent: AgentService, adapter: PiAdapter) { self.agent = agent; _model = StateObject(wrappedValue: PiSettingsModel(agent: agent, adapter: adapter)) }
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            settingGroup("Pi configuration") {
                SettingsRow(title: "Provider") {
                    Picker("Provider", selection: $model.configuration.provider) { ForEach(PiProviderID.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                if model.configuration.provider == .local { localRows }
                else { SettingsNote(text: "Pi uses its existing providers and authentication. Model and thinking controls in Chat are supplied by Pi.") }
            }
            settingGroup("New Pi sessions") {
                SettingsRow(title: "Default agent mode") {
                    Picker("Default agent mode", selection: Binding(get: { agent.configuration.defaultPermission }, set: { mode in
                        do { try agent.updateDefaultPermission(mode) } catch { model.result = error.localizedDescription }
                    })) { Text("Approval").tag(ComposerPermissionMode.approval); Text("Autonomous").tag(ComposerPermissionMode.autonomous) }.labelsHidden()
                }
            }
            HStack { Spacer(); Button("Save Pi Settings") { model.save() }.disabled(model.busy || model.loadFailed || agent.configurationChangeUnavailable != nil) }
            if let reason = agent.configurationChangeUnavailable { detail(reason) }
            if !model.result.isEmpty { detail(model.result) }
        }.disabled(model.loadFailed)
    }
    @ViewBuilder private var localRows: some View {
        SettingsRow(title: "Connection type") { Text("OpenAI-compatible") }
        SettingsRow(title: "Endpoint") { TextField("http://127.0.0.1:8000/v1", text: $model.endpoint).textFieldStyle(.roundedBorder).onChange(of: model.endpoint) { _, _ in model.endpointChanged() } }
        SettingsRow(title: "Authentication", subtitle: model.configuration.local.authentication == .none ? "No Authorization header is sent." : nil) {
            Picker("Authentication", selection: $model.configuration.local.authentication) { Text("None").tag(PiLocalAuthentication.none); Text("API key / bearer token").tag(PiLocalAuthentication.apiKey) }.labelsHidden()
        }
        if model.configuration.local.authentication == .apiKey {
            SettingsRow(title: "API key", subtitle: model.replaceToken ? "Replacement pending save." : model.tokenStored ? "Stored in Keychain." : "Required for this authentication mode.") {
                HStack { SecureField("Unchanged", text: Binding(get: { model.token }, set: { model.token = $0; model.replaceToken = true })).textFieldStyle(.roundedBorder); Button("Remove") { model.token = ""; model.replaceToken = true; model.configuration.local.authentication = .none } }
            }
        }
        SettingsRow(title: "Legacy API key", subtitle: "Import for this endpoint and profile. macOS may ask permission once; existing entries are preserved.") {
            Button("Import Legacy Key…") { model.importLegacyCredential() }.disabled(model.busy || model.replaceToken)
        }
        SettingsRow(title: "Connection", subtitle: "Read-only model discovery. Pi sends all inference requests.") { Button(model.busy ? "Testing…" : "Test Connection") { model.testConnection() }.disabled(model.busy) }
        SettingsRow(title: "Default model", subtitle: "Exact server ID for Pi startup. Chat retains available session-specific choices.") {
            HStack {
                TextField("Model ID", text: $model.model).textFieldStyle(.roundedBorder).onChange(of: model.model) { _, _ in model.loadModel() }
                if !model.configuration.local.models.isEmpty {
                    Menu("Discovered…") { ForEach(model.configuration.local.models) { item in Button(item.id) { try? model.storeModelDraft(); model.model = item.id } } }
                }
            }
        }
        if !model.model.isEmpty {
            let item = model.configuration.local.models.first { $0.id == model.model }
            SettingsRow(title: "Reported context", subtitle: "Server metadata is preserved independently of Advanced overrides.") { Text(item?.contextWindow.map(String.init) ?? "Unknown") }
            SettingsRow(title: "Reported output") { Text(item?.maxTokens.map(String.init) ?? "Unknown") }
            DisclosureGroup("Advanced model limits") {
                SettingsRow(title: "Context override", subtitle: "Auto uses the reported value, otherwise leaves this to Pi. A number overrides it.") { TextField("Auto", text: $model.context).textFieldStyle(.roundedBorder) }
                SettingsRow(title: "Output override", subtitle: "Auto uses the reported value, otherwise leaves this to Pi. A number overrides it.") { TextField("Auto", text: $model.output).textFieldStyle(.roundedBorder) }
            }
            SettingsRow(title: "Reasoning support", subtitle: "Declare only when known for this model. Pi supplies Chat thinking levels.") { capabilityPicker($model.reasoning).disabled(item?.reasoning != nil) }
            SettingsRow(title: "Image support", subtitle: "Unknown stays unspecified in Pi configuration.") { capabilityPicker($model.images).disabled(item?.images != nil) }
        }
    }
    private func capabilityPicker(_ selection: Binding<String>) -> some View {
        Picker("Capability", selection: selection) { Text("Unknown").tag("auto"); Text("Supported").tag("yes"); Text("Unsupported").tag("no") }.labelsHidden()
    }
}
