import Foundation

public struct GitHubRepository: Sendable, Equatable {
    public let owner: String
    public let name: String
    public var slug: String { owner + "/" + name }
    public static func parse(remote: String) -> Self? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("git@github.com:") { value = "https://github.com/" + value.dropFirst(15) }
        guard let url = URL(string: value), url.host == "github.com" else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        return .init(owner: parts[0], name: parts[1])
    }
}
public enum GitHubAuthState: Sendable, Equatable {
    case githubCLI, milkCredential, signedOut, registrationRequired
}
public struct GitHubOAuthConfiguration: Sendable {
    public var clientID: String
    public init(clientID: String = "") { self.clientID = clientID }
    public var isConfigured: Bool { !clientID.isEmpty }
}
public protocol GitHubServing: Sendable {
    func authState() async -> GitHubAuthState
    func repository(_ repository: GitHubRepository) async throws -> JSONValue
    func pullRequests(_ repository: GitHubRepository) async throws -> JSONValue
    func issues(_ repository: GitHubRepository) async throws -> JSONValue
    func actions(_ repository: GitHubRepository) async throws -> JSONValue
}
public actor GitHubService: GitHubServing {
    private let credentials: any CredentialStoring
    private let configuration: GitHubOAuthConfiguration
    private let session: URLSession
    private let gh: URL?
    public init(credentials: any CredentialStoring = KeychainService(), configuration: GitHubOAuthConfiguration = .init(), session: URLSession = .shared, gh: URL? = nil) {
        self.credentials = credentials; self.configuration = configuration; self.session = session
        self.gh = gh ?? ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public func authState() async -> GitHubAuthState {
        if let gh, let result = try? await CommandRunner.run(.init(executable: gh, arguments: ["auth", "status", "--hostname", "github.com"])), result.status == 0 { return .githubCLI }
        if (try? credentials.read(account: "github.com")) != nil { return .milkCredential }
        return configuration.isConfigured ? .signedOut : .registrationRequired
    }
    private func get(_ path: String) async throws -> JSONValue {
        if await authState() == .githubCLI, let gh {
            let result = try await CommandRunner.run(.init(executable: gh, arguments: ["api", "--hostname", "github.com", path]))
            guard result.status == 0 else { throw MilkError.message("GitHub CLI request failed") }
            return try JSONDecoder().decode(JSONValue.self, from: result.output)
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/" + path)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Milk", forHTTPHeaderField: "User-Agent")
        if let token = try credentials.read(account: "github.com") { request.setValue("Bearer " + String(decoding: token, as: UTF8.self), forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MilkError.message("GitHub request failed. Check authentication, access, and rate limits.") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func repository(_ repo: GitHubRepository) async throws -> JSONValue { try await get("repos/" + repo.slug) }
    public func pullRequests(_ repo: GitHubRepository) async throws -> JSONValue { try await get("repos/" + repo.slug + "/pulls") }
    public func issues(_ repo: GitHubRepository) async throws -> JSONValue { try await get("repos/" + repo.slug + "/issues") }
    public func actions(_ repo: GitHubRepository) async throws -> JSONValue { try await get("repos/" + repo.slug + "/actions/runs") }
    public func beginDeviceAuthorization() async throws -> JSONValue {
        guard configuration.isConfigured else { throw MilkError.message("GitHub OAuth client ID is not configured for this build") }
        return try await oauth(path: "device/code", body: "client_id=\(configuration.clientID)&scope=repo")
    }
    public func completeDeviceAuthorization(deviceCode: String) async throws -> JSONValue {
        let result = try await oauth(path: "oauth/access_token", body: "client_id=\(configuration.clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code")
        if let token = result["access_token"].string { try credentials.write(Data(token.utf8), account: "github.com") }
        return result // Caller honors server polling interval/slow_down before retrying.
    }
    private func oauth(path: String, body: String) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://github.com/login/" + path)!)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MilkError.message("GitHub authorization failed") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
