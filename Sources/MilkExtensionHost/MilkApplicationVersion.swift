import Foundation

/// Product metadata comes from the running app, not a Swift version constant.
public struct MilkApplicationVersion {
    public let version: String?
    public let buildNumber: String?

    public init(bundle: Bundle) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    public static var current: Self {
        // SwiftPM executables/tests have no application Info.plist. Only those
        // unbundled launches may read the same canonical checkout files. A test
        // runner may expose Xcode metadata; that is never Milk's version.
        if Bundle.main.bundleURL.pathExtension == "app",
           Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Milk" {
            return Self(bundle: .main)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Self(version: read(root.appendingPathComponent("VERSION")), buildNumber: read(root.appendingPathComponent("BUILD_NUMBER")))
    }
    private init(version: String?, buildNumber: String?) { self.version = version; self.buildNumber = buildNumber }
    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
