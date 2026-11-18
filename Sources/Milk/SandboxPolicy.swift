import Foundation

/// Pure policy, above adapters. This does not enforce a sandbox or launch any process.
struct SandboxPolicy {
    var resolver = SandboxPathResolver()
    func evaluate(_ url: URL, action: SandboxFileAction, context: SandboxPolicyContext) -> SandboxPolicyDecision {
        func result(_ outcome: SandboxPolicyOutcome, _ rule: SandboxPolicyRule, _ path: SandboxResolvedPath? = nil,
                    _ boundaries: Set<String> = []) -> SandboxPolicyDecision {
            .init(outcome: outcome, rule: rule, action: action, path: path, boundaries: boundaries, subject: context.subject)
        }
        guard context.configurationIsValid else { return result(.deny, .invalidConfiguration) }
        guard (try? context.configuration.validate()) != nil else { return result(.deny, .invalidConfiguration) }
        guard context.configuration.enabled else { return result(.sandboxDisabled, .disabled) }
        do {
            let path = try resolver.resolve(url)
            let project = try resolver.resolve(context.roots.project)
            guard project.isDirectory else { return result(.deny, .unresolvedPath, path) }
            let protected = try context.configuration.protectedLocations.map { ($0.id, try resolver.resolve($0.url)) }
            let inactive = try context.roots.inactiveProfiles.map { ($0, try resolver.resolve($0.url)) }
            let active = try context.roots.activeProfile.map { ($0, try resolver.resolve($0.url)) }
            let folders = try (context.configuration.globalAllowedFolders + context.projectConfiguration.allowedFolders)
                .map { ($0, try resolver.resolve($0.url)) }
            let builds = try context.roots.writableBuildRoots.map { try resolver.resolve($0) }
            let profileIDs = inactive.map { $0.0.id } + (active.map { [$0.0.id] } ?? [])
            guard !profileIDs.contains(where: \.isEmpty), Set(profileIDs).count == profileIDs.count else { return result(.deny, .ambiguousRoots, path) }
            let snapshots = [path, project] + protected.map(\.1) + inactive.map(\.1) + folders.map(\.1) + builds + (active.map { [$0.1] } ?? [])
            guard snapshots.allSatisfy({ $0.revalidated(using: resolver) }) else { return result(.deny, .unresolvedPath, path) }
            // Conflicting profile ownership or same-priority folder permissions has no safe winner.
            let matchingInactive = inactive.filter { $0.1.contains(path) }
            let matchingFolders = folders.filter { $0.1.contains(path) }
            if let active, active.1.contains(path), !matchingInactive.isEmpty { return result(.deny, .ambiguousRoots, path) }
            if Set(matchingInactive.map { $0.0.id }).count > 1 || Set(matchingFolders.map { $0.0.access }).count > 1 {
                return result(.deny, .ambiguousRoots, path)
            }
            // Strongest-to-weakest precedence. Temporary grants are applied only AFTER this decision.
            let matchingProtected = protected.filter { $0.1.contains(path) }
            if !matchingProtected.isEmpty { return result(.requireProtectedLocationApproval, .protectedLocation, path, Set(matchingProtected.map { $0.0 })) }
            if !matchingInactive.isEmpty { return result(.requireSandboxApproval, .inactiveProfile, path, Set(matchingInactive.map { $0.0.id })) }
            if project.contains(path), context.projectConfiguration.access == .readOnly, action != .read { return result(.deny, .projectReadOnly, path) }
            if !matchingFolders.isEmpty {
                let permitted = matchingFolders.allSatisfy { $0.0.access.permits(action) }
                return result(permitted ? .allow : .requireSandboxApproval, .allowedFolder, path, Set(matchingFolders.map { $0.0.id }))
            }
            if let active, active.1.contains(path) {
                let permitted = context.subject == .agentRuntime || active.0.ownership == .managed
                return result(permitted ? .allow : .requireSandboxApproval, .activeProfile, path, [active.0.id])
            }
            if project.contains(path) { return result(.allow, .project, path) }
            // Explicit Milk-owned build roots are the normal-purpose exception to outside writes,
            // below protected/profile/project restrictions and persistent folder restrictions.
            if builds.contains(where: { $0.contains(path) }) { return result(.allow, .buildRoot, path) }
            return result(context.interaction == .autonomous && action == .read ? .allow : .requireSandboxApproval, .outsideProject, path)
        } catch { return result(.deny, .unresolvedPath) }
    }
}
