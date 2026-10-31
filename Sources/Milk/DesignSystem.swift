import SwiftUI
import AppKit

enum MilkTheme {
    // Named dynamic colors resolve in each native view's effective appearance.
    static func native(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, alpha: 1)
        }
    }
    static func pair(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: native(light, dark)) }
    // Preserve the original Light RGB exactly; resolve native Dark colors in
    // the requesting view's appearance, including live System changes.
    static func neutral(_ light: UInt32, dark: @escaping () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return NSColor(srgbRed: Double((light >> 16) & 255)/255, green: Double((light >> 8) & 255)/255, blue: Double(light & 255)/255, alpha: 1) }
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance { resolved = dark().usingColorSpace(.sRGB)! }
            return resolved
        }
    }
    static func neutralSurface(_ light: UInt32, dark: @escaping () -> NSColor) -> Color { Color(nsColor: neutral(light, dark: dark)) }
    static func raised(_ amount: CGFloat) -> NSColor {
        NSColor.controlBackgroundColor.blended(withFraction: amount, of: .labelColor) ?? .controlBackgroundColor
    }
    static func settingsTile(_ category:String)->Color {
        let value:UInt32
        switch category {case "Pi","Agents":value=0xC96442;case "Editor":value=0x4C6E9E;case "Agent":value=0x9A6A1E;case "Git":value=0xB5533C;case "Extensions":value=0x6E8A5F;case "Updates","Preview":value=0x5B7C99;case "Advanced":value=0x8C7AA6;default:value=0x8A867C}
        return pair(value,value)
    }
    static let switchOn = pair(0x2D9A5A,0x2D9A5A)
    static let canvas = neutralSurface(0xFAF9F5) { .windowBackgroundColor }
    static let sidebar = neutralSurface(0xF0EEE6) { NSColor.windowBackgroundColor.blended(withFraction: 0.025, of: .labelColor)! }
    static let surface = neutralSurface(0xF3F1EA) { raised(0.055) }
    static let elevatedSurface = neutralSurface(0xFFFFFF) { raised(0.085) }
    static let workspaceTabsSurface = neutralSurface(0xE2DED3) { raised(0.04) }
    static let segment = neutralSurface(0xECE9E0) { raised(0.04) }
    static let selectionSurface = neutralSurface(0xFFFFFF) { raised(0.20) }
    static let selectionSurfaceHover = neutralSurface(0xFFFFFF) { raised(0.24) }
    static let hoverSurface = neutralSurface(0xECE9E0) { raised(0.12) }
    static let selected = neutralSurface(0xE2DED2) { raised(0.20) }
    static let modeSelectionSurface = Color(nsColor: NSColor(name:nil) { appearance in
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return .clear }
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance { resolved = raised(0.20).usingColorSpace(.sRGB)! }
        return resolved
    })
    static let line = neutralSurface(0xE2DFD5) { .separatorColor }
    static let ink = neutralSurface(0x1F1E1B) { .labelColor }
    static let muted = neutralSurface(0x6B6860) { .secondaryLabelColor }
    static let tertiaryText = neutralSurface(0x898477) { .tertiaryLabelColor }
    static let primaryAction = Color(hex:0xFF4D00)
    static let primaryActionDisabled = Color(hex:0xA83B0C)
    static let accent = pair(0xC96442, 0xE5835D)
    static let green = pair(0x2D7A4A, 0x80BC8D)
    static let amber = pair(0x9A5700, 0xE4B065)
    static let red = pair(0xB3372E, 0xEF8B7E)
    static let selection = neutral(0xE8D4BD) { raised(0.25) }
    static let codeBackground = neutral(0xFFFFFF) { .textBackgroundColor }
    static let terminalBackground = neutral(0xFBFAF7) { .textBackgroundColor }
    static let codeText = neutral(0x27241F) { .labelColor }
    static let codeComment = neutral(0x89847D) { .tertiaryLabelColor }
    static let codeKeyword = native(0x9652A1, 0xD7A1DC)
    static let codeType = native(0x387A8F, 0x8FC8BF)
    static let codeString = native(0xA84A38, 0xE8AC8E)
    static let codeNumber = native(0x387A8F, 0xD4BE87)
    static let activitySurface = elevatedSurface
    static let composerSurface = elevatedSurface
    static let approvalSurface = elevatedSurface
    static let diffAdded = pair(0xEAF2EC, 0x303E30)
    static let diffRemoved = pair(0xF8EDEC, 0x49302A)
    static let defaultSidebarWidth: CGFloat = 248
    static let topHeight: CGFloat = 52
    static let statusHeight: CGFloat = 26
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct Hairline: View {
    var body: some View { MilkTheme.line.frame(height: 1) }
}

struct MilkButtonStyle: ButtonStyle {
    var selected = false
    var bordered = false
    var height: CGFloat? = 28
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MilkTheme.ink)
            .padding(.horizontal, 8).frame(minHeight: 28).frame(height: height)
            .background(selected ? (hovering || configuration.isPressed ? MilkTheme.selectionSurfaceHover : MilkTheme.selectionSurface) : (configuration.isPressed || hovering ? MilkTheme.hoverSurface : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected || bordered ? MilkTheme.line : .clear, lineWidth: 1))
            .onHover { hovering = $0 }
    }
}

struct StateDot: View {
    let state: AgentSession.State
    var body: some View {
        Group {
            switch state {
            case .running: RunningIndicator()
            case .idle: Circle().stroke(MilkTheme.muted.opacity(0.65), lineWidth: 1.5).frame(width: 7, height: 7)
            case .approval: Circle().fill(MilkTheme.amber).frame(width: 7, height: 7)
            case .error: Circle().fill(MilkTheme.red).frame(width: 7, height: 7)
            case .unread: Circle().fill(MilkTheme.green).frame(width: 7, height: 7)
            }
        }.frame(width: 12).accessibilityLabel(state.rawValue)
    }
}

private struct RunningIndicator: View {
    @State private var spinning=false
    var body: some View {
        Circle().trim(from:0.12,to:0.91).stroke(MilkTheme.accent,style:StrokeStyle(lineWidth:1.3,lineCap:.round))
            .rotationEffect(.degrees(spinning ? 420:60)).frame(width:10,height:10)
            .onAppear { spinning=false; withAnimation(.linear(duration:0.85).repeatForever(autoreverses:false)) { spinning=true } }
            .onDisappear { spinning=false }
    }
}

/// Static workspace identity; no project-derived letter or fill tile.
struct MilkCartonOutline:Shape {
    func path(in rect:CGRect)->Path {
        var path=Path()
        func line(_ points:[CGPoint]) {guard let first=points.first else{return};path.move(to:first);for point in points.dropFirst(){path.addLine(to:point)}}
        line([.init(x:5,y:9),.init(x:9,y:3),.init(x:16,y:3),.init(x:20,y:9),.init(x:20,y:23),.init(x:5,y:23),.init(x:5,y:9),.init(x:16,y:9),.init(x:20,y:9)])
        line([.init(x:16,y:3),.init(x:16,y:23)])
        line([.init(x:9,y:3),.init(x:16,y:9)])
        return path.applying(CGAffineTransform(scaleX:rect.width/24,y:rect.height/26))
    }
}
