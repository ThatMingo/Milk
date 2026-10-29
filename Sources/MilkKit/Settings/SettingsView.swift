import SwiftUI

public struct MilkSettingsView: View {
    @AppStorage("pi.executable") private var piPath = "/opt/homebrew/bin/pi"
    @AppStorage("editor.tabWidth") private var tabWidth = 4
    @AppStorage("editor.useTabs") private var useTabs = false
    @AppStorage("updates.automaticChecks") private var updateChecks = false
    private let updates: UpdateService
    public init(updates: UpdateService) { self.updates = updates }
    public var body: some View {
        TabView {
            Form {
                TextField("Pi executable", text: $piPath)
                Text("Milk reads your existing Pi configuration. Provider and model settings stay with Pi.").font(.caption).foregroundStyle(.secondary)
                Text("Approval gates supported Pi tools before execution. Existing Pi extensions retain Pi’s operating-system authority.").font(.caption).foregroundStyle(.secondary)
                Button("Reset Milk’s Workspace Trust Decisions") {
                    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("pi.projectTrust.") { UserDefaults.standard.removeObject(forKey: key) }
                }
            }.padding().tabItem { Label("Pi", systemImage: "bubble.left") }
            Form {
                Stepper("Tab width: \(tabWidth)", value: $tabWidth, in: 1...8)
                Toggle("Insert tabs instead of spaces", isOn: $useTabs)
                Text("Native TextKit 2 editing; syntax highlighting runs independently of language servers.").font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Label("Editor", systemImage: "curlybraces") }
            Form {
                Toggle("Check for updates automatically", isOn: $updateChecks).onChange(of: updateChecks) { updates.setAutomaticChecks(updateChecks) }
                Text(updates.status).font(.caption).foregroundStyle(.secondary)
                Button("Check for Updates") { updates.check() }.disabled(!updates.configured)
                Text("Milk sends no telemetry. Debug logs omit prompts, credentials, and raw process output.").font(.caption)
            }.padding().tabItem { Label("Updates & Privacy", systemImage: "arrow.down.circle") }
        }.frame(width: 560, height: 310)
    }
}
