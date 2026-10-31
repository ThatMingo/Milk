import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MilkExtensionHost

struct ExtensionsContent:View {
    @ObservedObject var service:ExtensionService
    @ObservedObject var agent:AgentService
    @ObservedObject var native:NativeExtensionManager
    let category:String
    let workspace:URL?
    let refreshOnOpen:Bool
    @State private var selected:String?
    @State private var feedback=""
    @State private var filter=""
    private var visible:[PiExtensionRecord] { service.records.filter { (category != "Enabled" || $0.enabled) && (filter.isEmpty || ($0.name+" "+$0.source+" "+$0.path).localizedCaseInsensitiveContains(filter)) } }
    private var nativeVisible:[NativeExtensionRecord] { native.records.filter { (category != "Enabled" || $0.enabled) && (filter.isEmpty || ($0.manifest.name+" "+$0.id).localizedCaseInsensitiveContains(filter)) } }
    private func chooseInstall() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=true
        if panel.runModal() == .OK,let url=panel.url { install(url) }
    }
    private func install(_ url:URL) { if url.pathExtension == "milkext" { NativeExtensionInstallFlow.review(manager:native,url:url) } else {service.install(url)} }
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Text(category == "Installed" ? "Installed extensions":category).font(.system(size:20,weight:.semibold)); Spacer()
                    HStack(spacing:6) { Image(systemName:"magnifyingglass"); TextField("Filter",text:$filter).textFieldStyle(.plain).accessibilityLabel("Filter extensions") }.font(.system(size:12)).padding(.horizontal,10).frame(width:200,height:28).background(MilkTheme.segment,in:RoundedRectangle(cornerRadius:8))
                    Button {service.refresh(workspace:workspace); Task { await native.checkIntegrity() }} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.plain).help("Refresh")
                    Button {chooseInstall()} label:{Label("Install…",systemImage:"plus").font(.system(size:12.5,weight:.medium)).padding(.horizontal,12).frame(height:28).foregroundStyle(MilkTheme.canvas).background(MilkTheme.ink,in:RoundedRectangle(cornerRadius:8))}.buttonStyle(.plain).disabled(service.busy || native.busy)
                }
                if service.pendingReload {
                    detail("Configuration saved for new Pi runtimes. Running sessions retain their currently loaded extensions.")
                    Button("Reconnect Idle Pi Runtimes") {
                        do { try service.reconnect(agent) } catch { feedback=error.localizedDescription }
                    }.disabled(agent.configurationChangeUnavailable != nil || service.busy)
                    if let reason=agent.configurationChangeUnavailable { detail(reason) }
                }
                if category == "Problems" {
                    ForEach(native.records.filter { $0.problem != nil }) { record in NativeExtensionCard(record:record,selected:selected == "native:"+record.id) { selected="native:"+record.id } }
                    ForEach(native.diagnostics,id:\.self) { Text($0).foregroundStyle(MilkTheme.red) }
                    if service.problems.isEmpty && native.records.allSatisfy({ $0.problem == nil }) { detail("No extension problems detected.") }
                    ScrollView { VStack(alignment:.leading,spacing:12) { ForEach(service.problems,id:\.self) { Text($0).textSelection(.enabled).foregroundStyle(MilkTheme.red) } } }
                } else if category == "Updates" {
                    ForEach(nativeVisible) { record in NativeExtensionCard(record:record,selected:selected == "native:"+record.id) { selected="native:"+record.id } }
                    detail("Select a Milk Extension to update it from a local .milkext. No online marketplace is configured. Pi: No verified extension update metadata is available. Local sources stay in place; Milk does not infer updates from version strings or contact registries.")
                    Spacer()
                } else {

                    ScrollView {
                        LazyVStack(spacing:12) {
                            ForEach(nativeVisible) { record in NativeExtensionCard(record:record,selected:selected == "native:"+record.id) { selected="native:"+record.id } }
                            ForEach(visible) {record in extensionCard(record)}

                        }
                    }
                }
                if let notice=service.notice { detail(notice) }
                if !feedback.isEmpty { detail(feedback) }
            }.padding(.horizontal,32).padding(.vertical,24).frame(maxWidth:824,maxHeight:.infinity,alignment:.topLeading).frame(maxWidth:.infinity,alignment:.top)
            MilkTheme.line.frame(width:1)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    if let record=native.records.first(where:{ "native:"+$0.id == selected }) { NativeExtensionDetails(manager:native,record:record) }
                    else if let record=service.records.first(where:{$0.id == selected}) {
                        HStack(spacing:10) {extensionIcon(record);VStack(alignment:.leading,spacing:3) {Text(record.name).font(.system(size:14,weight:.semibold));if let version=record.version {detail(version)};detail(record.scope)}}
                        if !record.required { HStack {Button(record.enabled ? "Disable":"Enable") {toggle(record,!record.enabled)}.frame(maxWidth:.infinity).disabled(record.required || record.toggleUnavailable != nil || service.busy);if record.removable {Button("Uninstall…",role:.destructive) {remove(record)}.frame(maxWidth:.infinity).disabled(service.busy || native.busy)}}.buttonStyle(SettingsButtonStyle()).controlSize(.small) }
                        Hairline()
                        Text("DIAGNOSTICS").font(.system(size:11,weight:.semibold)).foregroundStyle(MilkTheme.muted)
                        detail("Configured state: "+(record.enabled ? "Enabled":"Disabled"))
                        detail(record.kind)
                        detail("Applies to new runtimes; project resources require Pi trust.")
                        if let version=record.version { Text("Version: "+version) }
                        Text("Source: "+record.source).textSelection(.enabled)
                        Text(record.path).textSelection(.enabled)
                        if let problem=record.problem { Text(problem).foregroundStyle(MilkTheme.red) }
                        if record.required { detail("Required by Milk for provider configuration and the approval gate. It cannot be disabled or removed.") }
                        else {
                            if let reason=record.toggleUnavailable { detail(reason) }
                            if record.removable {
                                detail("Removes the entire local package registration through Pi. Local source files stay in place.")
                            } else { detail("Removal is unavailable for discovered files and packages without a verified safe local registration. Disable the resource to stop future loading.") }
                        }
                    } else { detail("Select an extension to view its details.") }
                }.padding(20).frame(maxWidth:.infinity,alignment:.topLeading)
            }.frame(width:280).background(MilkTheme.surface)
        }.onAppear { if refreshOnOpen || service.records.isEmpty { service.refresh(workspace:workspace) };if selected == nil {selected=native.records.first.map { "native:"+$0.id } ?? service.records.first?.id} }
            .onChange(of:workspace) { _,root in service.refresh(workspace:root) }
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in
                guard let provider=providers.first else { return false }
                _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in install(url) } } }
                return true
            }
    }
    private func toggle(_ record:PiExtensionRecord,_ enabled:Bool) {
        do {try service.setEnabled(record,enabled)} catch {feedback=error.localizedDescription}
    }
    private func extensionIcon(_ record:PiExtensionRecord)->some View {
        Text(String(record.name.prefix(1)).uppercased()).font(.system(size:16,weight:.bold)).foregroundStyle(.white).frame(width:40,height:40).background(record.required ? MilkTheme.settingsTile("Pi"):MilkTheme.settingsTile("Extensions"),in:RoundedRectangle(cornerRadius:10))
    }
    private func extensionCard(_ record:PiExtensionRecord)->some View {
        HStack(alignment:.top,spacing:14) {
            extensionIcon(record)
            VStack(alignment:.leading,spacing:6) {
                HStack(alignment:.firstTextBaseline,spacing:8) {Text(record.name).font(.system(size:14,weight:.semibold));if let version=record.version {Text(version).font(.system(size:11,design:.monospaced)).foregroundStyle(MilkTheme.muted)}}
                Text(record.kind).font(.system(size:12.5)).foregroundStyle(MilkTheme.muted)
                HStack(spacing:5) {badge(record.scope);if record.required {badge("Required")};if !record.enabled {badge("Disabled")}}
                if let problem=record.problem {Label(problem,systemImage:"exclamationmark.circle").font(.system(size:12)).foregroundStyle(MilkTheme.red).padding(8).frame(maxWidth:.infinity,alignment:.leading).background(MilkTheme.red.opacity(0.06),in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(MilkTheme.red.opacity(0.2)))}
            }.frame(maxWidth:.infinity,alignment:.leading)

        }.padding(.horizontal,16).padding(.vertical,14).frame(maxWidth:.infinity,alignment:.leading)
            .background(selected == record.id ? MilkTheme.selected:MilkTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(MilkTheme.line))
            .contentShape(Rectangle()).onTapGesture {selected=record.id}
            .accessibilityElement(children:.contain).accessibilityAction(named:Text("Show details")) {selected=record.id}
    }
    private func badge(_ text:String)->some View {Text(text).font(.system(size:11)).foregroundStyle(MilkTheme.muted).padding(.horizontal,7).frame(height:20).background(MilkTheme.segment,in:RoundedRectangle(cornerRadius:5))}
    private func remove(_ record:PiExtensionRecord) {
        let alert=NSAlert(); alert.messageText="Remove local Pi package registration?"; alert.informativeText="\(record.source)\n\nThis removes the package and its resources from Pi's personal configuration. Source files and running sessions are preserved."
        alert.addButton(withTitle:"Remove"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await service.uninstall(record); selected=nil } catch { feedback=error.localizedDescription } }
    }
}
