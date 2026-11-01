import Foundation

/// Opt-in verification inside the actual signed app, with a disposable identity.
enum ProviderCredentialVerification {
    static func run() -> Int32 {
        let endpoint = URL(string: "https://keychain-verification.invalid/" + UUID().uuidString)!
        let profile = "verification-" + UUID().uuidString
        func save(_ value: String) throws { try AgentProviderCredentials.save(value, agent: .pi, provider: "verification", endpoint: endpoint, profile: profile) }
        func read() throws -> String? { try AgentProviderCredentials.token(agent: .pi, provider: "verification", endpoint: endpoint, profile: profile) }
        defer { try? save("") }
        do {
            try save("disposable-verification-value")
            guard try AgentProviderCredentials.exists(agent: .pi, provider: "verification", endpoint: endpoint, profile: profile),
                  try read() == "disposable-verification-value" else { throw AgentError.message("Credential add/read/existence verification failed.") }
            try save("updated-disposable-value")
            guard try read() == "updated-disposable-value",
                  try AgentProviderCredentials.token(agent: .pi, provider: "verification", endpoint: endpoint, profile: profile + "-other") == nil else {
                throw AgentError.message("Credential update/scoping verification failed.")
            }
            try save("")
            guard try read() == nil else { throw AgentError.message("Credential removal verification failed.") }
            print("Data Protection Keychain add/read/update/existence/scoping/delete passed.")
            return 0
        } catch { print(error.localizedDescription); return 1 }
    }
}
