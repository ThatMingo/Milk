import AppKit
import SwiftUI
import MilkExtensionKit
import MilkExtensionHost

@MainActor extension ShellState {
    func chooseExtensionInstall(development: Bool = false) {
        let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=true; panel.treatsFilePackagesAsDirectories=false
        panel.message=development ? "Choose a built development .milkext. Milk tracks the source folder and runs a reviewed, controlled copy.":"Choose a .milkext native Milk Extension or a local Pi Extension."
        if panel.runModal() == .OK, let url=panel.url { installExtension(url,development:development) }
    }
    func installExtension(_ url: URL, development: Bool = false) {
        if url.pathExtension == "milkext" {
            NativeExtensionInstallFlow.review(manager:nativeExtensions,url:url,development:development)
        } else { extensions.install(url) }
    }
}
@MainActor enum NativeExtensionInstallFlow {
    static func showError(_ error: Error) { let alert=NSAlert(); alert.messageText="Milk Extension"; alert.informativeText=error.localizedDescription; alert.runModal() }
    static func accept(_ review: NativePackageInspection, delta: Set<ExtensionCapability>, update: Bool) -> Bool {
        let alert=NSAlert(); alert.alertStyle = .warning
        alert.messageText=update ? "Update trusted native extension?":"Trust and install native extension?"
        let capabilities=review.manifest.capabilities.map(\.rawValue).sorted().joined(separator:", ")
        alert.informativeText="\(review.manifest.name) · \(review.manifest.version)\n\(review.signature)\n\nThis extension contains native executable code. It runs inside Milk with Milk's process privileges. Only install extensions you trust. Capabilities govern supported Milk APIs; they are not a macOS sandbox.\n\nRequested capabilities: \(capabilities.isEmpty ? "None":capabilities)\n\(update ? "New capabilities: "+delta.map(\.rawValue).sorted().joined(separator:", "):"")\n\nFingerprint: \(review.fingerprint)"
        alert.addButton(withTitle:update ? "Trust & Update":"Trust & Install"); alert.addButton(withTitle:"Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func review(manager: NativeExtensionManager, url: URL, updating id: String? = nil, development: Bool = false, retrust: Bool = false) {
        do {
            let inspection=retrust ? try manager.inspector.inspect(url):try manager.inspect(url,updating:id)
            guard accept(inspection,delta:manager.capabilityDelta(inspection),update:id != nil) else { return }
            Task {
                do {
                    if let id, retrust { try await manager.trustModified(id,review:inspection,trusting:inspection.fingerprint,granting:inspection.capabilities) }
                    else if let id { try await manager.update(id,with:inspection,trusting:inspection.fingerprint,granting:inspection.capabilities) }
                    else { try await manager.install(inspection,trusting:inspection.fingerprint,granting:inspection.capabilities,development:development) }
                } catch { showError(error) }
            }
        } catch { showError(error) }
    }
}

struct NativeExtensionCard: View {
    let record: NativeExtensionRecord
    let selected: Bool
    let select: () -> Void
    var body: some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:"puzzlepiece.extension").font(.system(size:18)).foregroundStyle(.white).frame(width:40,height:40).background(MilkTheme.settingsTile("Extensions"),in:RoundedRectangle(cornerRadius:10))
            VStack(alignment:.leading,spacing:6) {
                HStack { Text(record.manifest.name).font(.system(size:14,weight:.semibold)); Text(record.manifest.version).font(.system(size:11,design:.monospaced)).foregroundStyle(MilkTheme.muted) }
                Text("Type: Milk Extension · API "+record.manifest.milkApi).foregroundStyle(MilkTheme.muted)
                Text((record.enabled ? "Enabled":"Disabled")+(record.current.developmentPath == nil ? " · Local":" · Development")+(record.restartRequired ? " · Restart Milk required":"")).font(.system(size:11)).foregroundStyle(MilkTheme.muted)
                if let problem=record.problem { Text(problem).foregroundStyle(MilkTheme.red).font(.system(size:12)) }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.horizontal,16).padding(.vertical,14).background(selected ? MilkTheme.selected:MilkTheme.elevatedSurface,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(MilkTheme.line)).contentShape(Rectangle()).onTapGesture(perform:select).accessibilityElement(children:.contain).accessibilityAction(named:Text("Show details"),select)
    }
}
struct NativeExtensionDetails: View {
    @ObservedObject var manager: NativeExtensionManager
    let record: NativeExtensionRecord
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(record.manifest.name).font(.system(size:16,weight:.semibold))
            Text(record.manifest.description ?? "Native Milk Extension")
            HStack {
                Button(record.enabled ? "Disable":"Enable") { run { try await manager.setEnabled(record.id,!record.enabled) } }
                Button("Uninstall…",role:.destructive) { uninstall() }
            }.disabled(manager.busy).buttonStyle(SettingsButtonStyle())
            Button("Update from .milkext…") {
                let panel=NSOpenPanel(); panel.canChooseDirectories=true; panel.canChooseFiles=true
                if panel.runModal() == .OK, let url=panel.url { NativeExtensionInstallFlow.review(manager:manager,url:url,updating:record.id) }
            }.disabled(manager.busy)
            if let source=record.current.developmentPath {
                Button("Review Development Build…") {
                    do {
                        let review=try manager.inspector.inspect(URL(fileURLWithPath:source))
                        guard NativeExtensionInstallFlow.accept(review,delta:manager.capabilityDelta(review),update:true) else { return }
                        run { try await manager.reloadDevelopment(record.id,review:review,trusting:review.fingerprint,granting:review.capabilities) }
                    } catch { NativeExtensionInstallFlow.showError(error) }
                }.disabled(manager.busy)
            }
            Button("Reveal Location") { NSWorkspace.shared.activateFileViewerSelecting([manager.packageURL(record)]) }
            Button("Review Integrity / Re-trust…") { NativeExtensionInstallFlow.review(manager:manager,url:manager.packageURL(record),updating:record.id,retrust:true) }.disabled(manager.busy)
            Hairline()
            detail("Type: Milk Extension")
            detail("ID: "+record.id)
            detail("Version: "+record.manifest.version)
            detail("Milk API: "+record.manifest.milkApi+" · requires Milk "+record.manifest.minimumMilkVersion)
            detail("Author: "+(record.manifest.author ?? "Not specified"))
            detail("State: "+(record.enabled ? "Enabled":"Disabled"))
            detail("Trust: "+(record.isTrusted ? "User trusted fingerprint":"Modified / blocked"))
            detail("Signature: "+record.current.signature)
            detail("Source: "+record.current.source).textSelection(.enabled)
            detail("Capabilities: "+record.manifest.capabilities.map(\.rawValue).sorted().joined(separator:", "))
            detail("Update: "+(record.restartRequired ? "Installed; Restart Milk required":"Use a newer local .milkext"))
            if record.current.developmentPath != nil { detail("Development extension · reviewed controlled copy") }
            if let problem=record.problem { Text(problem).foregroundStyle(MilkTheme.red).textSelection(.enabled) }
            detail("Binary remains mapped after disable/uninstall until Milk exits. User data is stored separately.")
        }.font(.system(size:12))
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { NativeExtensionInstallFlow.showError(error) } } }
    private func uninstall() {
        let alert=NSAlert(); alert.messageText="Uninstall \(record.manifest.name)?"; alert.informativeText="Removes all contributions and installed code/resources. Extension data is retained by default."
        let checkbox=NSButton(checkboxWithTitle:"Also remove extension data (including Keychain)",target:nil,action:nil); alert.accessoryView=checkbox
        alert.addButton(withTitle:"Uninstall"); alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { let removeData=checkbox.state == .on; run { try await manager.uninstall(record.id,removeData:removeData) } }
    }
}
