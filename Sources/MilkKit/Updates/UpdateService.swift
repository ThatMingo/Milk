import Foundation
import Sparkle
import Observation

@MainActor @Observable public final class UpdateService {
    public private(set) var status: String
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    public var configured: Bool { controller != nil }
    public init(bundle: Bundle = .main) {
        if let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String, feed.hasPrefix("https://"),
           let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            status = "Ready"
        } else { status = "Update feed/signing key not configured for this development build" }
    }
    public func check() { controller?.checkForUpdates(nil) }
    public func setAutomaticChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
}
