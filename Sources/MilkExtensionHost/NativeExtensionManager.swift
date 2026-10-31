import Foundation
import Combine
import MilkExtensionKit

public struct NativePackageReference: Codable, Equatable {
    public var manifest: ExtensionManifest
    public var fingerprint: String
    public var signature: String
    public var source: String
    public var developmentPath: String?
    public var fileName: String { fingerprint+".milkext" }
}
public struct NativeExtensionRecord: Codable, Identifiable, Equatable {
    public var id: String { current.manifest.id }
    public var current: NativePackageReference
    public var previous: NativePackageReference?
    public var enabled: Bool
    public var trustedFingerprint: String
    public var restartRequired: Bool
    public var problem: String?
    public var integrityProblem: Bool? = nil
    public var isTrusted: Bool { integrityProblem != true && current.fingerprint == trustedFingerprint }
    public var manifest: ExtensionManifest { current.manifest }
}

@MainActor public protocol NativeExtensionLoading: AnyObject {
    var keepsNativeCodeMapped: Bool { get }
    func load(_ inspection: NativePackageInspection) throws -> MilkExtension
}
@MainActor public final class NativeBundleLoader: NativeExtensionLoading {
    public let keepsNativeCodeMapped=true
    private static var bundles: [Bundle] = []
    static var residentFingerprints: [String:String] = [:]
    private static var principalOwners: [String:String] = [:]
    public init() {}
    public func load(_ inspection: NativePackageInspection) throws -> MilkExtension {
        let name=inspection.manifest.principalClass
        if let owner=Self.principalOwners[name], owner != inspection.manifest.id { throw NativeExtensionError.invalid("Principal class is already owned by another native extension.") }
        Self.principalOwners[name]=inspection.manifest.id
        Self.residentFingerprints[inspection.manifest.id]=inspection.fingerprint
        guard let bundle=Bundle(url:inspection.url) else { throw NativeExtensionError.invalid("Cannot open native extension bundle.") }
        try bundle.loadAndReturnError(); Self.bundles.append(bundle)
        guard let principal=bundle.classNamed(inspection.manifest.principalClass) as? MilkExtension.Type else { throw NativeExtensionError.invalid("Principal class must subclass MilkExtensionKit.MilkExtension. Link the host SDK dynamically.") }
        guard Bundle(for:principal).bundleURL.resolvingSymlinksInPath() == inspection.url.resolvingSymlinksInPath() else { throw NativeExtensionError.invalid("Principal class resolved outside the inspected bundle. Restart Milk before replacing native code.") }
        return principal.init()
    }
}

/// Immutable code versions + an atomic state.json pointer form the install/update transaction.
/// No operation writes Milk's source, app bundle, Pi source, or extension data during replacement.
@MainActor public final class NativeExtensionManager: ObservableObject {
    @Published public private(set) var records: [NativeExtensionRecord] = []
    @Published public private(set) var diagnostics: [String] = []
    @Published public private(set) var busy=false
    public let root: URL
    public let registry: ExtensionContributionRegistry
    public let processes=ExtensionProcessHost()
    public let inspector: NativePackageInspector
    public let catalogURL: URL
    public var focusSidebar: ((String) -> Void)?
    /// Milk supplies its existing approval UI/policy, including originating Pi session identity.
    public var authorize: (@MainActor (String,String,URL?,Int?) async throws -> Void)?
    public var onContributionsChanged: (() -> Void)?
    private let loader: any NativeExtensionLoading
    private var contexts: [String:NativeExtensionContext] = [:]
    private var instances: [String:MilkExtension] = [:]
    private var resident: [String:String] = [:]
    private var workspaceURL: URL?
    private var started=false
    private var quitting=false
    private var integrityWatcher: ExtensionIntegrityWatcher?
    private var integrityTask: Task<Void,Never>?
    public init(root: URL? = nil, loader: (any NativeExtensionLoading)? = nil, milkVersion: String = "0.7.0") {
        self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Milk",isDirectory:true)
        catalogURL=self.root.appendingPathComponent("ExtensionBridge/catalog.json")
        self.loader=loader ?? NativeBundleLoader(); inspector=NativePackageInspector(milkVersion:milkVersion); registry=ExtensionContributionRegistry()
        registry.onChange={ [weak self] in self?.publishCatalog(); self?.onContributionsChanged?() }
    }
    public func packageURL(_ record: NativeExtensionRecord) -> URL { versions(record.id).appendingPathComponent(record.current.fileName) }
    public func dataURL(_ id: String) -> URL { root.appendingPathComponent("ExtensionData/"+id,isDirectory:true) }
    private func directory(_ id: String) -> URL { root.appendingPathComponent("Extensions/"+id,isDirectory:true) }
    private func versions(_ id: String) -> URL { directory(id).appendingPathComponent("versions",isDirectory:true) }
    private func scheduleIntegrityReview() {
        integrityTask?.cancel()
        integrityTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:400_000_000)
            guard let self, !Task.isCancelled, !self.quitting else { return }
            while self.busy { try? await Task.sleep(nanoseconds:100_000_000); if Task.isCancelled || self.quitting { return } }
            await self.checkIntegrity()
        }
    }
    private func prepare() throws {
        for url in [root,root.appendingPathComponent("Extensions"),root.appendingPathComponent("ExtensionData"),root.appendingPathComponent("ExtensionStaging"),catalogURL.deletingLastPathComponent()] { try ensureDirectory(url) }
        if integrityWatcher == nil && !quitting { integrityWatcher=ExtensionIntegrityWatcher(url:root.appendingPathComponent("Extensions")) { [weak self] in self?.scheduleIntegrityReview() } }
    }
    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard (try url.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeExtensionError.invalid("Refusing symlinked extension storage: \(url.path)") }
    }
    private func validateRecord(_ record: NativeExtensionRecord) throws {
        guard record.id.range(of:#"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*){2,}$"#,options:.regularExpression) != nil,
              record.current.fingerprint.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil,
              record.previous == nil || (record.previous?.manifest.id == record.id && record.previous?.fingerprint.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil) else { throw NativeExtensionError.invalid("Invalid stored extension identity or fingerprint.") }
    }
    private func mappedFingerprint(_ id: String) -> String? { resident[id] ?? (loader is NativeBundleLoader ? NativeBundleLoader.residentFingerprints[id]:nil) }
    private func save(_ record: NativeExtensionRecord) throws {
        try validateRecord(record)
        try ensureDirectory(directory(record.id))
        try JSONEncoder().encode(record).write(to:directory(record.id).appendingPathComponent("state.json"),options:.atomic)
        if let index=records.firstIndex(where:{ $0.id == record.id }) { records[index]=record } else { records.append(record) }
    }
    private func record(_ id: String) throws -> NativeExtensionRecord {
        guard let record=records.first(where:{ $0.id == id }) else { throw NativeExtensionError.invalid("Extension is not installed: \(id)") }
        return record
    }
    public func inspect(_ url: URL, updating id: String? = nil) throws -> NativePackageInspection {
        let candidate=try inspector.inspect(url)
        if let id {
            let old=try record(id)
            guard candidate.manifest.id == id else { throw NativeExtensionError.invalid("An update must use the same extension ID.") }
            guard try ExtensionVersion(candidate.manifest.version) > ExtensionVersion(old.manifest.version) else { throw NativeExtensionError.invalid("An update must have a newer version.") }
        } else if records.contains(where:{ $0.id == candidate.manifest.id }) { throw NativeExtensionError.invalid("Duplicate extension ID. Use Update in Details.") }
        return candidate
    }
    public func capabilityDelta(_ candidate: NativePackageInspection) -> Set<ExtensionCapability> {
        candidate.capabilities.subtracting(records.first(where:{ $0.id == candidate.manifest.id }).map { Set($0.manifest.capabilities) } ?? [])
    }
    private func approved(_ review: NativePackageInspection, fingerprint: String, capabilities: Set<ExtensionCapability>) throws -> NativePackageInspection {
        guard fingerprint == review.fingerprint, review.capabilities.isSubset(of:capabilities) else { throw NativeExtensionError.invalid("Trust and all requested capabilities must be explicitly accepted.") }
        let current=try inspector.inspect(review.url)
        guard current.fingerprint == review.fingerprint else { throw NativeExtensionError.invalid("Package changed after review; inspect and approve it again.") }
        return current
    }
    private func stage(_ inspection: NativePackageInspection, development: Bool) throws -> NativePackageReference {
        try prepare(); let fm=FileManager.default
        let staging=root.appendingPathComponent("ExtensionStaging/"+UUID().uuidString+".milkext")
        defer { try? fm.removeItem(at:staging) }
        try fm.copyItem(at:inspection.url,to:staging)
        let copied=try inspector.inspect(staging)
        guard copied.fingerprint == inspection.fingerprint else { throw NativeExtensionError.invalid("Package changed while copying; no installation was committed.") }
        try ensureDirectory(directory(inspection.manifest.id)); try ensureDirectory(versions(inspection.manifest.id))
        let target=versions(inspection.manifest.id).appendingPathComponent(inspection.fingerprint+".milkext")
        if fm.fileExists(atPath:target.path) {
            guard try inspector.inspect(target).fingerprint == inspection.fingerprint else { throw NativeExtensionError.invalid("Existing staged package was modified.") }
        } else { try fm.moveItem(at:staging,to:target) }
        return .init(manifest:inspection.manifest,fingerprint:inspection.fingerprint,signature:inspection.signature,source:inspection.url.path,developmentPath:development ? inspection.url.path:nil)
    }
    /// UI calls only after displaying inspection, unsigned warning, and capability delta.
    public func install(_ review: NativePackageInspection, trusting fingerprint: String, granting capabilities: Set<ExtensionCapability>, development: Bool = false) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        let current=try approved(review,fingerprint:fingerprint,capabilities:capabilities)
        _ = try inspect(current.url)
        let reference=try stage(current,development:development)
        let record=NativeExtensionRecord(current:reference,previous:nil,enabled:true,trustedFingerprint:fingerprint,restartRequired:false,problem:nil)
        try ensureDirectory(dataURL(record.id)); try save(record)
        try await activate(record.id)
    }
    public func start() async {
        guard !started, !quitting else { return }; started=true; busy=true; defer { busy=false }
        do {
            try prepare()
            let fm=FileManager.default
            for child in try fm.contentsOfDirectory(at:root.appendingPathComponent("Extensions"),includingPropertiesForKeys:[.isSymbolicLinkKey]) {
                do {
                    guard (try child.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw NativeExtensionError.invalid("Symlinked extension state.") }
                    var saved=try JSONDecoder().decode(NativeExtensionRecord.self,from:Data(contentsOf:child.appendingPathComponent("state.json")))
                    guard saved.id == child.lastPathComponent, saved.id.range(of:#"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*){2,}$"#,options:.regularExpression) != nil,
                          saved.current.fingerprint.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil else { throw NativeExtensionError.invalid("Invalid stored extension identity.") }
                    try validateRecord(saved)
                    saved.restartRequired=false; records.append(saved)
                } catch { diagnostics.append("\(child.lastPathComponent): \(error.localizedDescription)") }
            }
            publishCatalog()
            for saved in records where saved.enabled {
                do { try await activate(saved.id) }
                catch {
                    if var failed=try? record(saved.id), let previous=failed.previous {
                        failed.current=previous; failed.previous=nil; failed.trustedFingerprint=previous.fingerprint
                        failed.enabled=false; failed.restartRequired=mappedFingerprint(saved.id) != nil
                        failed.problem="New version failed at launch; previous package restored. Review before enabling. "+error.localizedDescription
                        try? save(failed)
                    }
                    diagnostics.append("\(saved.manifest.name): \(error.localizedDescription)")
                }
            }
        } catch { diagnostics.append(error.localizedDescription) }
    }
    private func verify(_ record: NativeExtensionRecord) async throws -> NativePackageInspection {
        let inspector=self.inspector, url=packageURL(record)
        let inspected=try await Task.detached(priority:.utility) { try inspector.inspect(url) }.value
        guard inspected.manifest == record.manifest, inspected.fingerprint == record.current.fingerprint, inspected.fingerprint == record.trustedFingerprint else { throw NativeExtensionError.invalid("Installed package changed. Native code was blocked; review and re-trust before loading.") }
        return inspected
    }
    private func activate(_ id: String) async throws {
        guard !quitting, instances[id] == nil else { return }
        var saved=try record(id)
        do {
            let inspection: NativePackageInspection
            do { inspection=try await verify(saved); saved.integrityProblem=false }
            catch { saved.integrityProblem=true; throw error }
            if let mapped=mappedFingerprint(id), mapped != inspection.fingerprint {
                saved.restartRequired=true; saved.problem=nil; try save(saved); return
            }
            guard !quitting else { throw CancellationError() }
            try ensureDirectory(dataURL(id))
            let lease=ExtensionLease(id:id,grants:Set(saved.manifest.capabilities),workspace:workspaceURL)
            let context=NativeExtensionContext(lease:lease,registry:registry,dataRoot:dataURL(id),processHost:processes) { [weak self] action,workspace in
                guard let self, let authorize=self.authorize else { throw NativeExtensionError.invalid("Milk approval policy is unavailable.") }
                try await authorize(id,action,workspace,nil)
            }
            context.focus={ [weak self] in self?.focusSidebar?($0) }
            context.problem={ [weak self] message in Task { @MainActor in await self?.fail(id,message:message) } }
            contexts[id]=context
            // Conservatively mark even a failing native loader attempt as resident; no unsafe reload.
            if loader.keepsNativeCodeMapped { resident[id]=inspection.fingerprint }
            let instance=try loader.load(inspection); instances[id]=instance
            try await boundedLifecycle(seconds:10) { try await instance.activate(context:context) }
            guard lease.active, !quitting else { throw CancellationError() }
            saved.enabled=true; saved.problem=nil; saved.restartRequired=false; try save(saved)
        } catch {
            await revoke(id)
            saved.enabled=false; saved.problem=error.localizedDescription; try save(saved)
            throw error
        }
    }
    private func revoke(_ id: String) async {
        let context=contexts.removeValue(forKey:id); context?.revoke(); (context?.network as? ScopedNetwork)?.cancel()
        let instance=instances.removeValue(forKey:id)
        async let cleanup: Void=processes.stopAll(owner:id)
        if let instance { do { try await boundedLifecycle(seconds:2) { await instance.deactivate() } } catch { diagnostics.append("\(id): Deactivation exceeded its deadline; code remains mapped.") } }
        await cleanup
        for problem in processes.cleanupProblems where !diagnostics.contains(problem) { diagnostics.append(problem) }
    }
    private func fail(_ id: String, message: String, integrity: Bool = false) async {
        guard var saved=try? record(id) else { return }
        // Revoke first, including tasks that retained the context.
        contexts[id]?.revoke(); registry.removeAll(owner:id)
        saved.enabled=false; saved.problem=message; if integrity { saved.integrityProblem=true }
        do { try save(saved) } catch { diagnostics.append(error.localizedDescription) }
        await revoke(id)
    }
    public func setEnabled(_ id: String, _ enabled: Bool) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        var saved=try record(id)
        if enabled { saved.enabled=true; try save(saved); try await activate(id) }
        else { saved.enabled=false; await revoke(id); try save(saved) }
    }
    public func uninstall(_ id: String, removeData: Bool = false) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        var saved=try record(id); saved.enabled=false; await revoke(id); try save(saved)
        if removeData {
            try ScopedSecrets.removeAll(id)
            let url=dataURL(id); if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
        try FileManager.default.removeItem(at:directory(id)); records.removeAll { $0.id == id }
    }
    public func update(_ id: String, with review: NativePackageInspection, trusting fingerprint: String, granting capabilities: Set<ExtensionCapability>) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        let inspected=try approved(review,fingerprint:fingerprint,capabilities:capabilities)
        _ = try inspect(inspected.url,updating:id)
        let old=try record(id)
        // Stage and fully validate before revoking the functioning version.
        let reference=try stage(inspected,development:old.current.developmentPath != nil)
        await revoke(id)
        var next=old; next.current=reference; next.previous=old.current; next.trustedFingerprint=fingerprint; next.problem=nil; next.integrityProblem=false
        next.restartRequired=mappedFingerprint(id) != nil
        do {
            try save(next)
            if next.enabled && !next.restartRequired { try await activate(id) }
        } catch {
            await revoke(id)
            var rollback=old; rollback.problem="Update failed and previous package restored: \(error.localizedDescription)"
            if mappedFingerprint(id) != nil { rollback.enabled=false; rollback.restartRequired=true }
            try save(rollback)
            if rollback.enabled {
                try? await activate(id)
                if var recovered=try? record(id) { recovered.problem=rollback.problem; try save(recovered) }
            }
            throw error
        }
    }
    /// Same-version rebuilds are allowed only for explicitly marked development extensions, with fresh trust.
    public func reloadDevelopment(_ id: String, review: NativePackageInspection, trusting fingerprint: String, granting capabilities: Set<ExtensionCapability>) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        var saved=try record(id)
        guard saved.current.developmentPath != nil, review.manifest.id == id,
              try ExtensionVersion(review.manifest.version) >= ExtensionVersion(saved.manifest.version) else { throw NativeExtensionError.invalid("Development reload requires the same ID and an equal or newer version.") }
        let checked=try approved(review,fingerprint:fingerprint,capabilities:capabilities)
        let reference=try stage(checked,development:true)
        await revoke(id); saved.previous=saved.current; saved.current=reference; saved.trustedFingerprint=fingerprint
        saved.restartRequired=mappedFingerprint(id) != nil; saved.problem=nil; saved.integrityProblem=false
        try save(saved); if saved.enabled && !saved.restartRequired { try await activate(id) }
    }
    /// Revalidates all bytes before accepting a modified installed development/local package.
    public func trustModified(_ id: String, review: NativePackageInspection, trusting fingerprint: String, granting capabilities: Set<ExtensionCapability>) async throws {
        guard !busy, !quitting else { throw NativeExtensionError.invalid("An extension operation is already in progress.") }; busy=true; defer { busy=false }
        var saved=try record(id)
        guard review.url == packageURL(saved), review.manifest.id == id, review.manifest.version == saved.manifest.version else { throw NativeExtensionError.invalid("Re-trust applies only to the same installed identity/version. Use Update for a new version.") }
        let inspected=try approved(review,fingerprint:fingerprint,capabilities:capabilities)
        let ref=try stage(inspected,development:saved.current.developmentPath != nil)
        await revoke(id); saved.current=ref; saved.trustedFingerprint=fingerprint; saved.problem=nil; saved.enabled=true; saved.integrityProblem=false
        saved.restartRequired=mappedFingerprint(id) != nil; try save(saved)
        if !saved.restartRequired { try await activate(id) }
    }
    public func checkIntegrity() async {
        guard !busy, !quitting else { return }; busy=true; defer { busy=false }
        for saved in records {
            do { _ = try await verify(saved) }
            catch { if saved.enabled || saved.problem != error.localizedDescription || contexts[saved.id] != nil { await fail(saved.id,message:error.localizedDescription,integrity:true) } }
        }
    }
    public func setWorkspace(_ url: URL?) async {
        guard workspaceURL != url else { return }
        let previous=workspaceURL
        workspaceURL=url
        // Cancel workspace tasks before exposing the new workspace; processes retain their original identity.
        for context in contexts.values { context.workspaceChanged(url) }
        if let previous { await processes.stopAll(workspaceOnly:true,matchingWorkspace:previous) }
    }
    public func notifyWorkspaceFilesChanged() { for context in contexts.values { for observer in context.lease.observers { observer(workspaceURL) } } }
    public func shutdown() async {
        quitting=true; integrityTask?.cancel(); integrityWatcher?.stop(); integrityWatcher=nil
        for context in contexts.values { context.revoke() }
        let ids=Array(instances.keys)
        let cleanupTasks=ids.map { id in Task { @MainActor in await self.revoke(id) } }
        for task in cleanupTasks { await task.value }
        await processes.stopAll()
    }
    public func reservePiCommands(_ names: [String]) async {
        registry.reservedCommands.formUnion(names)
        let conflicts=registry.commands.filter { names.contains($0.item.name) }
        for conflict in conflicts { await fail(conflict.owner,message:"Slash command /"+conflict.item.name+" conflicts with an active Pi command. Rename the native contribution.") }
    }
    public func executeCommand(_ name: String, arguments: String) async throws -> Bool {
        guard let command=registry.commands.first(where:{ $0.item.name == name }), contexts[command.owner]?.lease.active == true else { return false }
        try await command.item.perform(arguments); return true
    }
    public func invokePiTool(id: String, arguments: Data, workspace: URL, session: Int) async throws -> String {
        guard let tool=registry.tools.first(where:{ $0.id == id }), let context=contexts[tool.owner], context.lease.active,
              workspaceURL == workspace else { throw NativeExtensionError.invalid("Native Pi contribution is inactive or belongs to a different workspace.") }
        guard let authorize else { throw NativeExtensionError.invalid("Milk approval policy is unavailable.") }
        // Always use Milk's policy too, including requests arriving over the bridge UI channel.
        try await authorize(tool.owner,"Pi tool \(tool.piName)\n"+String(decoding:arguments,as:UTF8.self),workspace,session)
        try context.lease.check(.pi)
        guard workspaceURL == workspace, registry.tools.contains(where:{ $0.id == id }) else { throw NativeExtensionError.invalid("Contribution changed during approval.") }
        return try await tool.item.perform(arguments,.init(workspaceURL:workspace))
    }
    public func piPrompt(_ id: String, workspace: URL) throws -> String {
        guard workspaceURL == workspace, let prompt=registry.prompts[id] else { throw NativeExtensionError.invalid("Native prompt resource is unavailable.") }
        return prompt
    }
    private func publishCatalog() {
        do { try prepare(); try registry.piCatalogData().write(to:catalogURL,options:.atomic) }
        catch { if diagnostics.last != error.localizedDescription { diagnostics.append(error.localizedDescription) } }
    }
}

/// Recoverable async lifecycle deadlines; cannot recover a native crash or a blocked main thread.
@MainActor private func boundedLifecycle(seconds: Double, operation: @escaping @MainActor () async throws -> Void) async throws {
    var completed=false
    var work: Task<Void,Never>?
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
        work=Task { @MainActor in
            do { try await operation(); if !completed { completed=true; continuation.resume() } }
            catch { if !completed { completed=true; continuation.resume(throwing:error) } }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))
            if !completed { completed=true; work?.cancel(); continuation.resume(throwing:NativeExtensionError.invalid("Extension lifecycle deadline exceeded.")) }
        }
    }
}
