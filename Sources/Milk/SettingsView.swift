import SwiftUI
import AppKit

struct SettingsContent: View {
    @ObservedObject var state:ShellState
    let category:String
    @ObservedObject var settings:SettingsService
    @ObservedObject var updates:UpdateService
    @ObservedObject var workspace:WorkspaceStore
    @ObservedObject var agent:AgentService
    @State private var feedback=""
    init(state:ShellState,category:String) {
        self.state=state; self.category=category; settings=state.settings; updates=state.updates; workspace=state.workspace; agent=state.agent
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:SettingsMetrics.sectionSpacing) {
                switch category {
                case "General": general
                case "Agents", "Pi": AgentsSettingsView(state:state)
                case "Editor": editor
                case "Agent": agentSettings
                case "Git": git
                case "Extensions": extensions
                case "Preview": preview
                case "Updates": updateSettings
                default:
                    if let page=state.nativeExtensions.registry.settings.first(where:{ $0.id == category }) { page.item.content(.init(workspaceURL:workspace.workspace?.url)).id(page.id) }
                    else { advanced }
                }
                if !feedback.isEmpty { Text(feedback).foregroundStyle(MilkTheme.muted).textSelection(.enabled) }
            }.frame(maxWidth:760,alignment:.leading).padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:.infinity,alignment:.topLeading)
        }
    }
    private var general:some View {
        VStack(alignment:.leading,spacing:SettingsMetrics.sectionSpacing) {
            settingGroup("Appearance") {
                SettingsRow(title:"Appearance",subtitle:"System follows macOS automatically.") {
                    Picker("Appearance",selection:$settings.appearance) { ForEach(MilkAppearance.allCases,id:\.self) {Text($0.rawValue).tag($0)} }.labelsHidden().pickerStyle(.segmented)
                }
            }
            settingGroup("Launch") {
                SettingsRow(title:"Restore last workspace",subtitle:"Restores its layout, files and saved sessions.") {Toggle("Restore last workspace",isOn:$settings.restoreWorkspace).labelsHidden()}
            }
        }
    }
    private var editor:some View {
        settingGroup("Editor") {
            SettingsRow(title:"Font size") {Stepper("\(workspace.preferences.fontSize,specifier:"%.1f") pt",value:$workspace.preferences.fontSize,in:9...32,step:0.5).fixedSize()}
            SettingsRow(title:"Indentation") {Picker("Indentation",selection:$workspace.preferences.usesTabs) {Text("Spaces").tag(false);Text("Tabs").tag(true)}.labelsHidden().fixedSize()}
            SettingsRow(title:"Tab / indent width") {Stepper("\(workspace.preferences.indentWidth)",value:$workspace.preferences.indentWidth,in:1...8).fixedSize()}
            settingsToggle("Word wrap",isOn:$workspace.preferences.wordWrap)
            SettingsRow(title:"Editor defaults",subtitle:"Changes apply immediately to open editors.") {
                Button("Reset…") {confirm("Reset editor preferences?","Restores font size, indentation and wrapping. Files, buffers and undo history are preserved.") {workspace.preferences=EditorPreferences()}}
            }
        }
    }
    private var agentSettings:some View {
        settingGroup("New sessions") {
            SettingsRow(title:"Default agent mode",subtitle:"Existing sessions keep their current permissions.") {
                Picker("Permission mode",selection:Binding(get:{agent.configuration.defaultPermission},set:{mode in
                    do {try agent.updateDefaultPermission(mode)} catch {feedback=error.localizedDescription}
                })) {Text("Autonomous").tag(ComposerPermissionMode.autonomous);Text("Approval").tag(ComposerPermissionMode.approval)}.labelsHidden().pickerStyle(.segmented)
            }
            SettingsRow(title:"Default model",subtitle:"Configure the provider in Settings → Agents.") {Text(agent.configuration.omlx.enabled ? agent.configuration.omlx.defaultModel ?? "Not selected":"Pi configured default").lineLimit(1)}
            SettingsNote(text:"The composer controls the current session's model, reasoning effort and permissions.")
        }
    }
    private var git:some View {
        settingGroup("Local Git") {
            SettingsRow(title:"Executable",subtitle:"/usr/bin/git") {Text(FileManager.default.isExecutableFile(atPath:"/usr/bin/git") ? "Available":"Unavailable").foregroundStyle(MilkTheme.muted)}
            if let repo=workspace.git.repository {SettingsRow(title:"Repository",subtitle:repo.root.path) {Text(repo.branch)}}
            settingsToggle("Side-by-side diffs by default",isOn:$settings.gitSideBySide)
            SettingsNote(text:"Fetch, Pull and Push remain explicit Git actions. Commits use your configured Git identity and credential helpers.")
        }
    }
    private var preview:some View {
        settingGroup("New workspace defaults") {
            SettingsRow(title:"Viewport",subtitle:"Existing workspaces keep their saved viewport.") {Picker("Viewport",selection:$settings.previewDevice) {ForEach(PreviewDevice.allCases,id:\.self){Text($0.rawValue).tag($0)}}.labelsHidden().fixedSize()}
            SettingsNote(text:"Hiding Preview keeps Milk-owned servers running. Stop, workspace close and Quit clean up owned servers. External servers remain independent.")
        }
    }
    private var extensions:some View {
        settingGroup("Extensions") {
            settingsToggle("Refresh discovery on open",isOn:$settings.refreshExtensionsOnOpen)
            SettingsRow(title:"Installed extensions",subtitle:"Native Milk Extensions and separate Pi Extensions.") {Button("Manage…") {state.takeover="Extensions"}}
        }
    }
    private var updateSettings:some View {
        VStack(alignment:.leading,spacing:SettingsMetrics.sectionSpacing) {
            settingGroup("Milk \(updates.currentVersion)") {
                SettingsRow(title:"Update status") {Text(updates.state.label).textSelection(.enabled)}
                if let source=updates.source { SettingsNote(text:(updates.localTestSource ? "Local test source: ":"Update source: ")+source.absoluteString) }
                SettingsActionRow { Button("Check for Updates") { Task { await updates.check() } }.disabled(updates.state == .checking) }
                settingsToggle("Automatically check once per day",isOn:$settings.automaticUpdates)
                    .onChange(of:settings.automaticUpdates) { _,enabled in Task { await updates.automaticCheckIfNeeded(enabled:enabled) } }
                if let checked=updates.checkedAt { SettingsNote(text:"Last checked: \(checked.formatted())") }
                if updates.localTestSource { SettingsNote(text:"Test metadata only. Automatic checks and installation are disabled for local manifests.") }
                if case .available(let manifest)=updates.state {
                    SettingsNote(text:"\(manifest.version) · \(manifest.channel)").fontWeight(.medium)
                    if let notes=manifest.releaseNotes { SettingsNote(text:notes).textSelection(.enabled) }
                    if let url=manifest.releaseURL { SettingsActionRow {Link("Release Information",destination:url)} }
                    SettingsActionRow { Button("Download & Install…") { Task { do { try await updates.install() } catch { feedback=error.localizedDescription } } }.disabled(!updates.canInstall) }
                }
                SettingsNote(text:"Development build. Production feed, signed update verification and installation adapter are not configured. Milk will never install an unverified archive.")
            }
        }
    }
    private var advanced:some View {
        VStack(alignment:.leading,spacing:SettingsMetrics.sectionSpacing) {
            settingGroup("Diagnostics") {
                SettingsNote(text:"Pi data: \(state.extensions.agentDirectory.path)").textSelection(.enabled)
                SettingsNote(text:"Pi executable: \(resolvedPi)").textSelection(.enabled)
                SettingsNote(text:"oMLX: \(agent.omlxStatus.detail)")
                SettingsNote(text:"Endpoint: \(agent.configuration.omlx.endpoint.absoluteString)").textSelection(.enabled)
                SettingsNote(text:"Preview temporary root: \(FileManager.default.temporaryDirectory.appendingPathComponent("dev.milk/Preview-v1").path)").textSelection(.enabled)
                SettingsActionRow { Button("Copy Diagnostics") {
                    let text="Milk \(updates.currentVersion)\nPi \(state.agentInstallations.store.state.selected == nil ? "not installed" : "selected")\nRuntime: \(resolvedPi)\nPi data: \(state.extensions.agentDirectory.path)\noMLX endpoint: \(agent.configuration.omlx.endpoint.absoluteString)\noMLX reachable: \(agent.omlxStatus.reachable)\nGit: /usr/bin/git\nPreview: \(state.preview.state.rawValue)\nUpdates: \(updates.state.label)"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); feedback="Diagnostics copied. Credentials are excluded."
                } }
            }
            settingGroup("Local update testing") {
                SettingsActionRow { Button("Choose Test Manifest…") {
                    let panel=NSOpenPanel(); panel.canChooseDirectories=false
                    if panel.runModal() == .OK,let url=panel.url { updates.useLocalManifest(url) }
                } }
                if updates.localTestSource { SettingsActionRow {Button("Clear Test Source") { updates.useLocalManifest(nil) }} }
                SettingsNote(text:"Select a local schema 1 JSON update manifest. This validates version comparison and error states without installing anything.")
            }
            settingGroup("Targeted resets") {
                SettingsActionRow { Button("Reset General & Preview Defaults…") {
                    confirm("Reset general and Preview defaults?","Resets appearance, workspace launch restore, default viewport, discovery refresh and automatic update checks. Existing workspaces, layouts, files, sessions, Pi history, provider settings, Keychain secrets and saved workspace Preview state are preserved.") { settings.resetGeneralAndPreview() }
                } }
                SettingsActionRow { Button("Reset Current Layout…") {
                    confirm("Reset current workspace layout?","Restores the default panel layout. Files, sessions, projects and secrets are preserved.") { state.applyPreset(.chat) }
                } }
            }
        }
    }
    private var resolvedPi:String {
        (try? state.agentInstallations.selectedInstallation(verifyIntegrity: false))?.executable.path ?? "Not installed or not verified"
    }
    private func confirm(_ title:String,_ text:String,action:()->Void) {
        let alert=NSAlert(); alert.messageText=title; alert.informativeText=text; alert.addButton(withTitle:"Reset"); alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

struct PiSettingsContent:View {
    @ObservedObject var agent:AgentService
    @StateObject private var model:RuntimeSettingsModel
    @State private var feedback=""
    init(agent:AgentService) { self.agent=agent; _model=StateObject(wrappedValue:RuntimeSettingsModel(agent:agent)) }
    var body:some View {
        VStack(alignment:.leading,spacing:SettingsMetrics.sectionSpacing) {
            settingGroup("Provider") {
                SettingsRow(title:"Provider") {
                    Picker("Provider",selection:Binding(get:{model.providerID},set:{model.selectProvider($0)})) { ForEach(PiProviderID.allCases) { Text($0.title).tag($0) } }.labelsHidden().fixedSize()
                }
                SettingsRow(title:"Use selected provider",subtitle:"When off, Pi uses its own provider configuration.") { Toggle("Use selected provider",isOn:Binding(get:{model.providerEnabled},set:{model.providerEnabled=$0})).labelsHidden().tint(MilkTheme.green) }
                switch model.providerAdapter.configurationKind {
                case .omlx: OMLXProviderConfigurationRows(model:model,agent:agent)
                }
            }
            settingGroup("New sessions") {
                SettingsRow(title:"Default agent mode",subtitle:"Approval asks before commands and file changes.") {
                    Picker("Default agent mode",selection:Binding(get:{agent.configuration.defaultPermission},set:{ mode in
                        do {try agent.updateDefaultPermission(mode);model.configuration.defaultPermission=mode} catch {feedback=error.localizedDescription}
                    })) {Text("Autonomous").tag(ComposerPermissionMode.autonomous);Text("Approval").tag(ComposerPermissionMode.approval)}.labelsHidden().pickerStyle(.segmented)
                }
            }
            HStack { Spacer(); Button("Save Provider Settings") {model.configuration.defaultPermission=agent.configuration.defaultPermission;model.save()}.disabled(model.busy || agent.configurationChangeUnavailable != nil) }
            if let reason=agent.configurationChangeUnavailable {detail(reason)}
            if !model.result.isEmpty {detail(model.result)}
            if !feedback.isEmpty {detail(feedback)}
        }
    }
}
struct OMLXProviderConfigurationRows:View {
    @ObservedObject var model:RuntimeSettingsModel
    @ObservedObject var agent:AgentService
    private var status:ProviderInspection { model.connectionStatus ?? ProviderInspection(omlx:agent.omlxStatus) }
    var body:some View {
        SettingsRows {
        SettingsRow(title:"Endpoint") { TextField("http://host:port",text:$model.endpoint).textFieldStyle(.roundedBorder) }
        SettingsRow(title:"Status") { Text(status.checkedAt == nil && model.connectionStatus == nil ? "Not tested":status.reachable ? (status.authenticated == false ? "Authentication required":"Reachable"):"Unreachable").foregroundStyle(status.reachable ? MilkTheme.green:MilkTheme.muted) }
        SettingsRow(title:"Authentication",subtitle:model.replaceToken ? (model.token.isEmpty ? "Token will be removed on save.":"Replacement pending save."):model.tokenStored ? "Token stored in Keychain.":"Optional token, if required by the server.") {
            HStack(spacing:6) { SecureField("Unchanged",text:Binding(get:{model.token},set:{model.editToken($0)})).textFieldStyle(.roundedBorder);Button("Remove") {model.editToken("")} }
        }
        SettingsRow(title:"Model",subtitle:"Models are supplied by the external provider.") {
            if model.detected.isEmpty {TextField("Model ID",text:$model.model).textFieldStyle(.roundedBorder)}
            else { Picker("Model",selection:$model.model) {Text("Choose…").tag("");ForEach(model.detected,id:\.self){Text($0).tag($0)}}.labelsHidden() }
        }.onChange(of:model.model) {_,value in model.reasoning=model.configuration.omlx.reasoningModels.contains(value);model.images=model.configuration.omlx.imageModels.contains(value)}
        SettingsRow(title:"Reasoning support",subtitle:"Declare only if supported by the selected model.") {Toggle("Reasoning support",isOn:$model.reasoning).labelsHidden().tint(MilkTheme.green)}
        SettingsRow(title:"Image support") {Toggle("Image support",isOn:$model.images).labelsHidden().tint(MilkTheme.green)}
        SettingsRow(title:"Connection",subtitle:"Milk connects to this external server; it does not run it or manage its models.") {Button(model.busy ? "Testing…":"Test Connection") {model.testConnection()}.disabled(model.busy)}
        ForEach(status.models.filter { $0.state != nil || $0.loaded != nil }) {item in SettingsRow(title:item.id) {Text(item.state ?? (item.loaded == true ? "Loaded":"Not loaded")).foregroundStyle(MilkTheme.muted)} }
    }
}
}

func detail(_ value:String) -> some View { Text(value).font(.system(size:11.5)).foregroundStyle(MilkTheme.muted).fixedSize(horizontal:false,vertical:true) }
func settingGroup<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View {
    VStack(alignment:.leading,spacing:6) {
        Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(MilkTheme.muted).padding(.leading,4)
        Group(subviews:content()) { rows in
            VStack(spacing:0) { ForEach(rows) {row in row; if row.id != rows.last?.id {Hairline()} } }
        }.background(MilkTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(MilkTheme.line))
    }.toggleStyle(SettingsSwitchStyle()).controlSize(.small)
}
func settingsToggle(_ title:String,isOn:Binding<Bool>) -> some View {
    SettingsRow(title:title) { Toggle(title,isOn:isOn).labelsHidden().toggleStyle(SettingsSwitchStyle()).tint(MilkTheme.green) }
}
