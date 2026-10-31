import AppKit
import Combine

// Global defaults live in UserDefaults; workspace layouts, sessions and Preview memories
// remain in their existing stores. Secrets never enter this model.
enum MilkAppearance: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
@MainActor final class SettingsService: ObservableObject {
    private let defaults: UserDefaults
    private let persist: Bool
    @Published var appearance: MilkAppearance { didSet { save("appearance", appearance.rawValue); applyAppearance() } }
    @Published var restoreWorkspace: Bool { didSet { save("restoreWorkspace", restoreWorkspace) } }
    @Published var previewDevice: PreviewDevice { didSet { save("previewDevice", previewDevice.rawValue) } }
    @Published var automaticUpdates: Bool { didSet { save("automaticUpdates", automaticUpdates) } }
    @Published var gitSideBySide: Bool { didSet { save("gitSideBySide", gitSideBySide) } }
    @Published var refreshExtensionsOnOpen: Bool { didSet { save("refreshExtensionsOnOpen", refreshExtensionsOnOpen) } }
    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults=defaults; self.persist=persist
        appearance=MilkAppearance(rawValue: defaults.string(forKey:"Milk.settings.appearance") ?? "") ?? .system
        restoreWorkspace=defaults.object(forKey:"Milk.settings.restoreWorkspace") as? Bool ?? true
        previewDevice=PreviewDevice(rawValue:defaults.string(forKey:"Milk.settings.previewDevice") ?? "") ?? .desktop
        automaticUpdates=defaults.object(forKey:"Milk.settings.automaticUpdates") as? Bool ?? false
        gitSideBySide=defaults.object(forKey:"Milk.settings.gitSideBySide") as? Bool ?? defaults.object(forKey:"Milk.git.sideBySide") as? Bool ?? false
        refreshExtensionsOnOpen=defaults.object(forKey:"Milk.settings.refreshExtensionsOnOpen") as? Bool ?? true
    }
    private func save(_ key:String,_ value:Any) { if persist { defaults.set(value,forKey:"Milk.settings."+key) } }
    func applyAppearance() {
        NSApp.appearance=appearance == .system ? nil : NSAppearance(named:appearance == .dark ? .darkAqua:.aqua)
        for window in NSApp.windows { window.appearance=nil; window.backgroundColor=window.isOpaque ? NSColor(MilkTheme.canvas):.clear; window.contentView?.needsDisplay=true }
    }
    func resetGeneralAndPreview() {
        appearance = .system; restoreWorkspace=true; previewDevice = .desktop
        automaticUpdates=false; refreshExtensionsOnOpen=true
    }
    static func validatedEditor(_ value:EditorPreferences) -> EditorPreferences {
        var result=value
        result.fontSize=value.fontSize.isFinite ? min(32,max(9,value.fontSize)):12.5
        result.indentWidth=min(8,max(1,value.indentWidth))
        return result
    }
}
