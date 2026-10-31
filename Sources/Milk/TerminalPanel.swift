import AppKit
import SwiftUI
import SwiftTerm

@MainActor final class MilkTerminalView: TerminalView {
    static let scrollbackLines = 10_000
    private var appliedDarkAppearance: Bool?
    init(fontSize: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 350),
                   font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                   options: TerminalOptions(scrollback: Self.scrollbackLines))
        identifier = NSUserInterfaceItemIdentifier("milk.terminal.emulator")
        setAccessibilityLabel("Terminal")
        applyMilkAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); applyMilkAppearance()
    }
    static func palette(dark: Bool) -> [SwiftTerm.Color] {
        var values: [UInt32] = dark
            ? [0x24211E, 0xEF8B7E, 0x80BC8D, 0xE4B065, 0x90B9EC, 0xD7A1DC, 0x8FC8BF, 0xD8D0C4,
               0xA69A89, 0xFFAA9C, 0xA1D8A2, 0xF4CD87, 0xBAD5FF, 0xECC2F0, 0xB0E7DD, 0xFFF8EC]
            : [0x27241F, 0xB3372E, 0x287644, 0x8F6000, 0x315EAE, 0x9652A1, 0x187582, 0x777166,
               0x898477, 0xC43B32, 0x317E42, 0x986700, 0x3C69C4, 0xA13AA6, 0x00808E, 0x4E4941]
        if dark {
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                for (index, color) in [(0, NSColor.textBackgroundColor), (7, .secondaryLabelColor), (8, .tertiaryLabelColor), (15, .labelColor)] {
                    let rgb = color.usingColorSpace(.sRGB)!
                    let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
                    let alpha = rgb.alphaComponent
                    func channel(_ foreground: CGFloat, _ base: CGFloat) -> UInt32 { UInt32(((foreground * alpha + base * (1 - alpha)) * 255).rounded()) }
                    values[index] = channel(rgb.redComponent, background.redComponent) << 16 | channel(rgb.greenComponent, background.greenComponent) << 8 | channel(rgb.blueComponent, background.blueComponent)
                }
            }
        }
        return values.map { SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) }
    }
    func applyMilkAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard appliedDarkAppearance != dark else { return }
        appliedDarkAppearance = dark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = MilkTheme.terminalBackground.usingColorSpace(.sRGB)!
            nativeForegroundColor = MilkTheme.codeText.usingColorSpace(.sRGB)!
            caretColor = MilkTheme.codeText.usingColorSpace(.sRGB)!
            selectedTextBackgroundColor = MilkTheme.selection.usingColorSpace(.sRGB)!
            selectedTextForegroundColor = MilkTheme.codeText.usingColorSpace(.sRGB)!
            installColors(Self.palette(dark: dark))
        }
    }
    func clearDisplay() {
        // Feed display control sequences locally. Nothing is written to the PTY,
        // so cwd, shell input, running jobs and shell history remain untouched.
        feed(text: "\u{1B}[2J\u{1B}[H")
        clearScrollback()
    }
}

/// Intercepts only macOS clipboard chords with terminal focus. Ctrl+C / Ctrl+D,
/// arrows, IME, Unicode and interactive-program keys stay with SwiftTerm.
@MainActor final class TerminalContainer: NSView {
    let terminal: MilkTerminalView
    init(terminal: MilkTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.removeFromSuperview(); terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]; addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === terminal,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": terminal.copy(self); return true
        case "v": terminal.paste(self); return true
        case "k": terminal.clearDisplay(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private struct NativeTerminal: NSViewRepresentable {
    let session: TerminalSession
    let fontSize: Double
    func makeNSView(context: Context) -> TerminalContainer { TerminalContainer(terminal: session.view) }
    func updateNSView(_ container: TerminalContainer, context: Context) {
        if container.terminal.font.pointSize != fontSize { container.terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        container.terminal.applyMilkAppearance()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 300)
    }
}

struct TerminalPanel: View {
    @ObservedObject var service: TerminalService
    @ObservedObject var workspace: WorkspaceStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ExtensionSlot(point:.terminalToolbar)
                Image(systemName: "terminal").font(.system(size: 11))
                Text("Terminal").fontWeight(.medium)
                if let session = service.session { Text(URL(fileURLWithPath: session.shell).lastPathComponent).foregroundStyle(MilkTheme.muted) }
                Spacer(minLength: 0)
                if let status = service.status { Text(status).foregroundStyle(MilkTheme.muted).lineLimit(1) }
                Button { service.session?.view.clearDisplay() } label: { Image(systemName: "clear") }
                    .buttonStyle(MilkButtonStyle()).help("Clear display and scrollback (⌘K)").accessibilityLabel("Clear Terminal")
                Button { service.restart() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(MilkButtonStyle()).disabled(service.restarting)
                    .help("Restart Terminal at workspace root").accessibilityLabel("Restart Terminal")
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 34).background(MilkTheme.canvas)
            Hairline()
            if let session = service.session {
                NativeTerminal(session: session, fontSize: workspace.preferences.fontSize).id(session.id)
            } else {
                VStack(spacing: 8) {
                    Text(service.error ?? "Starting Terminal…").foregroundStyle(MilkTheme.muted).textSelection(.enabled)
                    if service.error != nil { Button("Restart Terminal") { service.restart() }.buttonStyle(MilkButtonStyle(bordered: true)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(MilkTheme.surface)
            .onAppear { service.ensureStarted(fontSize: workspace.preferences.fontSize); DispatchQueue.main.async { service.focusIfRequested() } }
            .onChange(of:service.focusRequest) { _,_ in DispatchQueue.main.async { service.focusIfRequested() } }
            .onChange(of: service.workspace) { _, _ in service.ensureStarted(fontSize: workspace.preferences.fontSize) }
    }
}
