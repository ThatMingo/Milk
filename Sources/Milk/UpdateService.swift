import Foundation
import Combine
import CryptoKit

struct MilkVersion: Comparable, Equatable {
    let numbers: [Int]
    let prerelease: [String]
    init(_ value:String) throws {
        let main=value.split(separator:"+",maxSplits:1,omittingEmptySubsequences:false)[0]
        let parts=main.split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        let components=parts[0].split(separator:".",omittingEmptySubsequences:false)
        guard (1...3).contains(components.count), components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }) else { throw AgentError.message("Invalid update version.") }
        numbers=components.map { Int($0)! } + Array(repeating:0,count:3-components.count)
        prerelease=parts.count == 2 ? parts[1].split(separator:".",omittingEmptySubsequences:false).map(String.init):[]
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { throw AgentError.message("Invalid prerelease version.") }
    }
    static func < (lhs:Self,rhs:Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (l,r) in zip(lhs.prerelease,rhs.prerelease) where l != r {
            if let a=Int(l),let b=Int(r) { return a<b }
            if Int(l) != nil { return true }; if Int(r) != nil { return false }
            return l<r
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
struct UpdateManifest: Codable, Equatable {
    var schemaVersion: Int
    var bundleIdentifier: String
    var version: String
    var channel: String
    var releaseNotes: String?
    var releaseURL: URL?
    var downloadURL: URL?
    var sha256: String?
    var minimumSystemVersion: String?
    func validate(identity:String) throws {
        guard schemaVersion == 1, bundleIdentifier == identity, channel == "stable" || channel == "preview" else { throw AgentError.message("Unsupported update manifest or application identity.") }
        _ = try MilkVersion(version)
        if let downloadURL { guard downloadURL.scheme == "https", downloadURL.host != nil, downloadURL.user == nil, downloadURL.password == nil else { throw AgentError.message("Updates require an HTTPS download URL without credentials.") } }
        if let releaseURL { guard releaseURL.scheme == "https",releaseURL.host != nil, releaseURL.user == nil, releaseURL.password == nil else { throw AgentError.message("Invalid release information URL.") } }
        if let sha256 { guard sha256.count == 64,sha256.allSatisfy(\.isHexDigit) else { throw AgentError.message("Invalid update checksum.") } }
        if let minimumSystemVersion { _ = try MilkVersion(minimumSystemVersion) }
    }
}
enum UpdateState: Equatable {
    case unconfigured, idle, checking, current, available(UpdateManifest), failed(String)
    var label:String {
        switch self {
        case .unconfigured: return "No update source configured"
        case .idle: return "Ready to check"
        case .checking: return "Checking for updates…"
        case .current: return "Milk is up to date for this source"
        case .available(let manifest): return "Milk \(manifest.version) is available"
        case .failed(let text): return text
        }
    }
}
/// A production adapter must authenticate metadata and verify the archive's signature,
/// version, Team ID and bundle identity before replacing the app. None is installed in dev builds.
@MainActor protocol UpdateInstaller {
    func downloadVerifyAndInstall(_ manifest:UpdateManifest, expectedIdentity:String) async throws
}
@MainActor final class UpdateService: ObservableObject {
    static let developmentVersion="0.7.0"
    let currentVersion:String
    let identity:String
    @Published private(set) var state:UpdateState = .unconfigured
    @Published private(set) var checkedAt:Date?
    @Published private(set) var source:URL?
    @Published private(set) var localTestSource=false
    private let defaults:UserDefaults
    private let session:URLSession
    private let installer:UpdateInstaller?
    private var revision=UUID()
    var canInstall:Bool { installer != nil && !localTestSource }
    init(defaults:UserDefaults = .standard, session:URLSession = .shared, installer:UpdateInstaller? = nil, currentVersion:String? = nil, identity:String? = nil) {
        self.defaults=defaults; self.session=session; self.installer=installer
        self.currentVersion=currentVersion ?? Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? Self.developmentVersion
        self.identity=identity ?? Bundle.main.bundleIdentifier ?? "dev.milk.phase1"
        if let path=defaults.string(forKey:"Milk.update.testManifest"), path.hasPrefix("/") { source=URL(fileURLWithPath:path); localTestSource=true }
        else if let value=Bundle.main.object(forInfoDictionaryKey:"MilkUpdateFeedURL") as? String, let url=URL(string:value), url.scheme == "https" { source=url }
        state=source == nil ? .unconfigured:.idle
    }
    func useLocalManifest(_ url:URL?) {
        revision=UUID(); checkedAt=nil
        if let url, url.isFileURL { defaults.set(url.path,forKey:"Milk.update.testManifest"); source=url; localTestSource=true }
        else {
            defaults.removeObject(forKey:"Milk.update.testManifest"); localTestSource=false
            source=(Bundle.main.object(forInfoDictionaryKey:"MilkUpdateFeedURL") as? String).flatMap(URL.init(string:))
        }
        state=source == nil ? .unconfigured:.idle
    }
    func check() async {
        guard let source else { state = .unconfigured; return }
        let token=UUID(); revision=token; state = .checking
        do {
            let data:Data
            if source.isFileURL {
                data=try await Task.detached { try Data(contentsOf:source) }.value
            } else {
                guard source.scheme == "https",source.user == nil,source.password == nil else { throw AgentError.message("Update feed must use HTTPS without credentials.") }
                var request=URLRequest(url:source); request.timeoutInterval=15; request.cachePolicy = .reloadIgnoringLocalCacheData
                let (value,response)=try await session.data(for:request)
                guard let http=response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw AgentError.message("Update source returned an invalid response.") }
                data=value
            }
            guard revision == token else { return }
            guard data.count<=1_000_000 else { throw AgentError.message("Update manifest is too large.") }
            let manifest=try JSONDecoder().decode(UpdateManifest.self,from:data)
            try manifest.validate(identity:identity)
            state=try MilkVersion(manifest.version)>MilkVersion(currentVersion) ? .available(manifest):.current
            checkedAt=Date()
        } catch { if revision == token { state = .failed("Update check failed: \(error.localizedDescription)") } }
    }
    func automaticCheckIfNeeded(enabled:Bool) async {
        guard enabled, source != nil, !localTestSource else { return }
        let last=defaults.object(forKey:"Milk.update.lastAutomaticCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last)>86400 else { return }
        defaults.set(Date(),forKey:"Milk.update.lastAutomaticCheck"); await check()
    }
    func install() async throws {
        guard case .available(let manifest)=state, canInstall, let installer else { throw AgentError.message("Installation is unavailable in this development build. Production distribution and signature verification must be configured first.") }
        try manifest.validate(identity:identity)
        guard manifest.downloadURL != nil, manifest.sha256 != nil else { throw AgentError.message("Update artifact URL/checksum metadata is missing.") }
        guard try MilkVersion(manifest.version)>MilkVersion(currentVersion) else { throw AgentError.message("Update must be newer than this app.") }
        if let minimum=manifest.minimumSystemVersion {
            let os=ProcessInfo.processInfo.operatingSystemVersion
            guard try MilkVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") >= MilkVersion(minimum) else { throw AgentError.message("This update needs macOS \(minimum) or newer.") }
        }
        try await installer.downloadVerifyAndInstall(manifest,expectedIdentity:identity)
    }
}
