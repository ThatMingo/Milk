import Foundation
import Security

/// Opt-in actual-app verification. Run ID/phase are public controls, never credentials.
/// Only UUID-scoped disposable names and synthetic values; no personal credential reads.
enum ProviderCredentialVerification {
    static func run() -> Int32 {
        func option(_ name: String) -> String? {
            guard let index=CommandLine.arguments.firstIndex(of:name), CommandLine.arguments.count > index+1 else { return nil }
            return CommandLine.arguments[index+1]
        }
        let identifier: UUID
        if let raw=option("--keychain-run-id") {
            guard let value=UUID(uuidString:raw) else { print("Invalid disposable Keychain verification ID."); return 1 }
            identifier=value
        } else { identifier=UUID() }
        let phase=option("--keychain-phase") ?? "all"
        guard ["all","keep","read","authorize","cleanup"].contains(phase) else { print("Unknown Keychain verification phase."); return 1 }
        let endpoint=URL(string:"https://keychain-verification.invalid/"+identifier.uuidString)!
        let profile="verification-"+identifier.uuidString
        let account=AgentProviderCredentials.account(agent:.pi,provider:"verification",endpoint:endpoint,profile:profile)
        func save(_ value: String) throws { try AgentProviderCredentials.save(value,agent:.pi,provider:"verification",endpoint:endpoint,profile:profile) }
        func read() throws -> String? { try AgentProviderCredentials.token(agent:.pi,provider:"verification",endpoint:endpoint,profile:profile) }
        func isolation() throws {
            guard try AgentProviderCredentials.token(agent:.pi,provider:"verification",endpoint:endpoint,profile:profile+"-other") == nil,
                  try AgentProviderCredentials.token(agent:.pi,provider:"other",endpoint:endpoint,profile:profile) == nil,
                  try AgentProviderCredentials.token(agent:.pi,provider:"verification",endpoint:endpoint.appendingPathComponent("other"),profile:profile) == nil,
                  try AgentProviderCredentials.token(agent:.init(rawValue:"verification-other"),provider:"verification",endpoint:endpoint,profile:profile) == nil else {
                throw AgentError.message("Disposable credential isolation verification failed.")
            }
        }
        func cleanup() throws {
            let query=AgentProviderCredentials.query(service:AgentProviderCredentials.service,account:account)
            let code=try AgentProviderCredentials.withKeychain(interactive:CommandLine.arguments.contains("--keychain-interactive")) { AgentProviderCredentials.delete(query as CFDictionary) }
            guard code == errSecSuccess || code == errSecItemNotFound, try read() == nil else {
                throw AgentError.message("Disposable Keychain cleanup failed (\(code)). Use the creating build or explicitly authorize cleanup.")
            }
        }
        do {
            switch phase {
            case "all","keep":
                try save("disposable-verification-value")
                guard try AgentProviderCredentials.exists(agent:.pi,provider:"verification",endpoint:endpoint,profile:profile),
                      try read() == "disposable-verification-value" else { throw AgentError.message("Credential add/read/existence verification failed.") }
                try save("updated-disposable-value")
                guard try read() == "updated-disposable-value" else { throw AgentError.message("Credential update verification failed.") }
                try isolation()
                if phase == "all" { try cleanup() }
                print("Normal macOS Keychain save/read/update/existence/isolation passed; "+(phase == "all" ? "delete verified.":"disposable item retained for relaunch verification."))
            case "read":
                guard try read() == "updated-disposable-value" else { throw AgentError.message("Retained disposable item could not be read.") }
                try isolation()
                print("Normal macOS Keychain retained-item read/isolation passed in this process.")
            case "authorize":
                guard try AgentProviderCredentials.importLegacy(agent:.pi,provider:"verification",endpoint:endpoint,profile:profile),
                      try read() == "updated-disposable-value" else { throw AgentError.message("Disposable recovery/normal-read verification failed.") }
                print("Explicit normal macOS Keychain authorization read passed.")
            default:
                try cleanup(); print("Normal macOS Keychain disposable cleanup verified.")
            }
            return 0
        } catch {
            print(error.localizedDescription)
            if phase == "all" || phase == "keep" {
                do { try cleanup() } catch { print("Disposable item cleanup also failed; retain its creating build for recovery.") }
            }
            return 1
        }
    }
}
