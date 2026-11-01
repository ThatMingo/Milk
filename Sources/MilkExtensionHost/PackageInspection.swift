import Foundation
import CryptoKit
import Security
import MilkExtensionKit

public enum NativeExtensionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// Semantic version precedence, including prereleases. Build metadata is not precedence.
public struct ExtensionVersion: Comparable, Equatable {
    let numbers: [Int]
    let prerelease: [String]
    public init(_ text: String) throws {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard text.range(of:pattern,options:.regularExpression) != nil else { throw NativeExtensionError.invalid("Invalid semantic version: \(text)") }
        let main=text.split(separator:"+",maxSplits:1)[0].split(separator:"-",maxSplits:1)
        let parsed=main[0].split(separator:".").compactMap { Int($0) }
        guard parsed.count == 3 else { throw NativeExtensionError.invalid("Version number exceeds supported range.") }
        numbers=parsed; prerelease=main.count == 2 ? main[1].split(separator:".").map(String.init):[]
        guard !prerelease.contains(where: { $0.allSatisfy(\.isNumber) && $0.count > 1 && $0.first == "0" }) else { throw NativeExtensionError.invalid("Invalid prerelease version.") }
    }
    public static func < (a: Self, b: Self) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x,y) in zip(a.prerelease,b.prerelease) where x != y {
            let xn=x.allSatisfy(\.isNumber), yn=y.allSatisfy(\.isNumber)
            if xn && yn { return x.count == y.count ? x<y:x.count<y.count }
            return xn != yn ? xn:x<y
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public struct NativePackageInspection {
    public let url: URL
    public let manifest: ExtensionManifest
    public let fingerprint: String
    public let signature: String
    public var capabilities: Set<ExtensionCapability> { Set(manifest.capabilities) }
}

/// Inspection never calls Bundle.load/principalClass or executes package code.
public struct NativePackageInspector {
    public let milkVersion: String
    public init(milkVersion: String = MilkApplicationVersion.current.version ?? "") { self.milkVersion=milkVersion }
    public func inspect(_ url: URL) throws -> NativePackageInspection {
        let fm=FileManager.default
        guard url.isFileURL, url.pathExtension == "milkext", (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true else { throw NativeExtensionError.invalid("Choose a .milkext native bundle directory.") }
        let fingerprint=try Self.fingerprint(url)
        let data=try Data(contentsOf:url.appendingPathComponent("Contents/Resources/manifest.json"))
        guard data.count <= 65536 else { throw NativeExtensionError.invalid("Manifest exceeds 64 KB.") }
        let manifest: ExtensionManifest
        do { manifest=try JSONDecoder().decode(ExtensionManifest.self,from:data) }
        catch { throw NativeExtensionError.invalid("Malformed manifest: \(error.localizedDescription)") }
        guard manifest.id.count <= 200, manifest.id.range(of:#"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*){2,}$"#,options:.regularExpression) != nil else { throw NativeExtensionError.invalid("Extension ID must be a lowercase reverse-DNS identifier.") }
        guard !manifest.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, manifest.name.count <= 120 else { throw NativeExtensionError.invalid("A display name is required (maximum 120 characters).") }
        _ = try ExtensionVersion(manifest.version)
        guard manifest.milkApi == MilkExtensionAPI.version else { throw NativeExtensionError.invalid("Unsupported Milk Extension API \(manifest.milkApi). This Milk supports API \(MilkExtensionAPI.version).") }
        guard try ExtensionVersion(manifest.minimumMilkVersion) <= ExtensionVersion(milkVersion) else { throw NativeExtensionError.invalid("Requires Milk \(manifest.minimumMilkVersion) or later.") }
        guard Set(manifest.capabilities).count == manifest.capabilities.count else { throw NativeExtensionError.invalid("Duplicate capability declarations.") }
        guard Self.component(manifest.executable), manifest.principalClass.range(of:#"^[A-Za-z_][A-Za-z0-9_.]*$"#,options:.regularExpression) != nil else { throw NativeExtensionError.invalid("Invalid executable or principal class.") }
        let executable=url.appendingPathComponent("Contents/MacOS/"+manifest.executable)
        guard fm.isExecutableFile(atPath:executable.path), (try executable.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile == true else { throw NativeExtensionError.invalid("Native bundle executable is missing or not executable.") }
        let handle=try FileHandle(forReadingFrom:executable); defer { try? handle.close() }
        let header=try handle.read(upToCount:16) ?? Data()
        // Phase 7 targets arm64 macOS, and accepts MH_BUNDLE rather than script executables.
        guard header.count == 16, Array(header.prefix(8)) == [0xcf,0xfa,0xed,0xfe,0x0c,0,0,1], Array(header[12..<16]) == [8,0,0,0] else { throw NativeExtensionError.invalid("Executable must be an arm64 Mach-O loadable bundle (MH_BUNDLE).") }
        let infoData=try Data(contentsOf:url.appendingPathComponent("Contents/Info.plist"))
        guard infoData.count <= 65536, let info=try PropertyListSerialization.propertyList(from:infoData,format:nil) as? [String:Any],
              info["CFBundlePackageType"] as? String == "BNDL", info["CFBundleExecutable"] as? String == manifest.executable,
              info["NSPrincipalClass"] as? String == manifest.principalClass, info["CFBundleIdentifier"] as? String == manifest.id else { throw NativeExtensionError.invalid("Info.plist must match manifest identity, executable, and principal class, with package type BNDL.") }
        if let icon=manifest.icon {
            _ = try Self.contained(icon,root:url.appendingPathComponent("Contents/Resources"))
            guard fm.fileExists(atPath:url.appendingPathComponent("Contents/Resources/"+icon).path) else { throw NativeExtensionError.invalid("Manifest icon is missing.") }
        }
        return NativePackageInspection(url:url.standardizedFileURL,manifest:manifest,fingerprint:fingerprint,signature:Self.signature(url))
    }
    static func component(_ text: String) -> Bool { !text.isEmpty && text != "." && text != ".." && !text.contains("/") && !text.contains("\\") && !text.contains("\0") }
    static func contained(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"), !relative.split(separator:"/",omittingEmptySubsequences:false).contains("..") else { throw NativeExtensionError.invalid("Expected a contained relative path.") }
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        let result=root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard result.path.hasPrefix(base.path+"/") else { throw NativeExtensionError.invalid("Path escapes extension scope.") }
        return result
    }
    public static func fingerprint(_ input: URL) throws -> String {
        let fm=FileManager.default
        guard (try input.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeExtensionError.invalid("Symlinked extension packages are unsupported.") }
        // Enumerate relative names ourselves. Foundation's URL enumerator may normalize
        // /var and /private/var differently, so dropping an absolute-path prefix is unsafe.
        let root=input.resolvingSymlinksInPath()
        var entries: [(String,URL)] = [], pending=[""]
        while let relativeDirectory=pending.popLast() {
            let directory=relativeDirectory.isEmpty ? root:root.appendingPathComponent(relativeDirectory)
            for name in try fm.contentsOfDirectory(atPath:directory.path) {
                let relative=relativeDirectory.isEmpty ? name:relativeDirectory+"/"+name
                let file=root.appendingPathComponent(relative)
                let info=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey])
                guard info.isSymbolicLink != true, info.isDirectory == true || info.isRegularFile == true else { throw NativeExtensionError.invalid("Packages may not contain symlinks or special files.") }
                entries.append((relative,file))
                guard entries.count <= 10000 else { throw NativeExtensionError.invalid("Package exceeds 10,000 entries.") }
                if info.isDirectory == true { pending.append(relative) }
            }
        }
        var digest=SHA256(), total=0
        for (relative,file) in entries.sorted(by: { $0.0 < $1.0 }) {
            let info=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            let attributes=try fm.attributesOfItem(atPath:file.path)
            let regular=info.isRegularFile == true
            guard !regular || ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) <= 1 else { throw NativeExtensionError.invalid("Hard-linked package files are unsupported.") }
            let size=regular ? (info.fileSize ?? 0):0
            total += size
            guard total <= 128*1024*1024 else { throw NativeExtensionError.invalid("Package exceeds 128 MB.") }
            let mode=(attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            // Explicit lengths/type distinguish file boundaries even for arbitrary binary resources.
            let header="\(relative.utf8.count):\(relative)\0\(mode)\0\(regular ? "file":"directory")\0\(size)\0"
            digest.update(data:Data(header.utf8))
            if regular {
                let data=try Data(contentsOf:file)
                guard data.count == size else { throw NativeExtensionError.invalid("Package changed during inspection.") }
                digest.update(data:data)
            }
        }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func signature(_ url: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSCheckAllArchitectures),nil) == errSecSuccess else { return "Unsigned / signature unverified" }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&info) == errSecSuccess,
           let team=(info as? [String:Any])?[kSecCodeInfoTeamIdentifier as String] as? String { return "Valid signature · team \(team) (publisher not approved by Milk)" }
        return "Ad-hoc signed / local (no verified publisher)"
    }
}
