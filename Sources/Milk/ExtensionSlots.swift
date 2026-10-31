import SwiftUI
import MilkExtensionKit
import MilkExtensionHost

private struct ExtensionRegistryKey: EnvironmentKey { static let defaultValue: ExtensionContributionRegistry? = nil }
private struct ExtensionActionContextKey: EnvironmentKey { static let defaultValue=ExtensionActionContext() }
extension EnvironmentValues {
    var milkExtensionRegistry: ExtensionContributionRegistry? { get { self[ExtensionRegistryKey.self] } set { self[ExtensionRegistryKey.self]=newValue } }
    var milkExtensionActionContext: ExtensionActionContext { get { self[ExtensionActionContextKey.self] } set { self[ExtensionActionContextKey.self]=newValue } }
}
/// Empty slots occupy no space when no extensions register content.
struct ExtensionSlot: View {
    @Environment(\.milkExtensionRegistry) private var registry
    @Environment(\.milkExtensionActionContext) private var context
    let point: ExtensionPoint
    var body: some View { if let registry { RegisteredExtensionSlot(registry:registry,point:point,context:context) } }
}
private struct RegisteredExtensionSlot: View {
    @ObservedObject var registry: ExtensionContributionRegistry
    let point: ExtensionPoint
    let context: ExtensionActionContext
    @State private var problem: String?
    var body: some View {
        HStack(spacing:4) {
            ForEach(Array((registry.views[point] ?? []).prefix(8))) { record in record.item.content(context).id(record.id) }
            ForEach(Array(registry.actions.filter { $0.point == point }.prefix(8))) { record in
                Button { Task { do { guard registry.actions.contains(where:{ $0.id == record.id }) else { return }; try await record.item.perform(context) } catch { problem=error.localizedDescription } } } label: { Label(record.item.title,systemImage:record.item.systemImage) }.buttonStyle(MilkButtonStyle())
            }
        }.alert("Extension action failed",isPresented:Binding(get:{ problem != nil },set:{ if !$0 { problem=nil } })) { Button("OK") { problem=nil } } message: { Text(problem ?? "") }
    }
}
struct ExtensionMenuActions: View {
    @Environment(\.milkExtensionRegistry) private var registry
    @Environment(\.milkExtensionActionContext) private var context
    let point: ExtensionPoint
    var fileURL: URL? = nil
    var text: String? = nil
    var body: some View {
        if let registry { RegisteredExtensionMenu(registry:registry,point:point,context:.init(workspaceURL:context.workspaceURL,fileURL:fileURL ?? context.fileURL,text:text ?? context.text)) }
    }
}
private struct RegisteredExtensionMenu: View {
    @ObservedObject var registry: ExtensionContributionRegistry
    let point: ExtensionPoint
    let context: ExtensionActionContext
    var body: some View {
        ForEach(registry.actions.filter { $0.point == point }) { record in
            Button(record.item.title) { Task {
                guard registry.actions.contains(where:{ $0.id == record.id }) else { return }
                do { try await record.item.perform(context) }
                catch { let alert=NSAlert(); alert.messageText="Extension action failed"; alert.informativeText=error.localizedDescription; alert.runModal() }
            } }
        }
    }
}
