import SwiftUI

struct ChatReadingAnchor: Equatable {
    var id: String
    var ownerID: String
    var order: [Int]
}

private struct ChatReadingMemoryKey: EnvironmentKey { static let defaultValue: ChatScrollMemory? = nil }
private struct ChatReadingOwnerKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var chatReadingMemory: ChatScrollMemory? {
        get { self[ChatReadingMemoryKey.self] }
        set { self[ChatReadingMemoryKey.self] = newValue }
    }
    var chatReadingOwner: String {
        get { self[ChatReadingOwnerKey.self] }
        set { self[ChatReadingOwnerKey.self] = newValue }
    }
}

private struct ChatReadingTarget: ViewModifier {
    @Environment(\.chatReadingMemory) private var memory
    @Environment(\.chatReadingOwner) private var owner
    let id: String
    let order: [Int]
    func body(content: Content) -> some View {
        content.id(id)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                memory?.setVisible(.init(id: id, ownerID: owner.isEmpty ? id : owner, order: order), visible: visible)
            }
            .onDisappear { memory?.removeVisible(id) }
    }
}
extension View {
    func chatReadingTarget(_ id: String, order: [Int]) -> some View { modifier(ChatReadingTarget(id: id, order: order)) }
}
