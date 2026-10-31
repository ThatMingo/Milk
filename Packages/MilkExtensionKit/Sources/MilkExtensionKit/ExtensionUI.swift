import SwiftUI
import AppKit

/// Semantic colors inherit the host's System, Light, or Dark appearance.
public enum ExtensionTheme {
    public static var text: Color { Color(nsColor: .labelColor) }
    public static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    public static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    public static var selected: Color { Color(nsColor: .selectedContentBackgroundColor).opacity(0.2) }
    public static var hover: Color { Color(nsColor: .labelColor).opacity(0.07) }
    public static var separator: Color { Color(nsColor: .separatorColor) }
    /// Milk identity orange, independent of appearance and the macOS user accent.
    public static var accent: Color { Color(.sRGB, red: 1, green: 77.0/255.0, blue: 0, opacity: 1) }
}
/// Small, stable native primitives for extension Settings and content.
public struct ExtensionSettingsRow<Content: View>: View {
    let title: String
    let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title=title; self.content=content() }
    public var body: some View { HStack { Text(title); Spacer(); content }.padding(12).background(ExtensionTheme.surface).toggleStyle(.switch).controlSize(.small) }
}
public struct ExtensionSettingsSection<Content: View>: View {
    let title: String
    let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title=title; self.content=content() }
    public var body: some View { VStack(alignment:.leading,spacing:6) { Text(title).font(.headline); VStack(spacing:1) { content }.clipShape(RoundedRectangle(cornerRadius:10)) } }
}
public struct ExtensionStatusBadge: View {
    let text: String
    public init(_ text: String) { self.text=text }
    public var body: some View { Text(text).font(.caption).padding(.horizontal,7).padding(.vertical,3).background(ExtensionTheme.hover,in:Capsule()) }
}
public struct ExtensionEmptyState: View {
    let title: String
    let message: String
    public init(_ title: String, message: String) { self.title=title; self.message=message }
    public var body: some View { VStack(spacing:8) { Text(title).font(.headline); Text(message).foregroundStyle(ExtensionTheme.secondaryText) }.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity) }
}
public struct ExtensionButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal,8).padding(.vertical,5).background(configuration.isPressed ? ExtensionTheme.selected:ExtensionTheme.hover,in:RoundedRectangle(cornerRadius:6))
    }
}
