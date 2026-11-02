import Foundation

/// Redacts admitted runtime credential values from Milk diagnostics; never persists/publishes them.
struct RuntimeDiagnosticRedactor {
    private let secrets: [String]
    init(environment: [String:String], additionalKeys: Set<String> = []) {
        var values: Set<String> = []
        for (key,value) in environment where !value.isEmpty {
            let name = key.uppercased()
            if additionalKeys.contains(key) || name == PiProviderSupport.credentialVariable ||
                (["API_KEY", "TOKEN", "SECRET", "PASSWORD", "ACCESS_KEY"].contains(where:name.contains) && !name.hasSuffix("_FILE")) {
                values.insert(value)
            }
            if PiEnvironment.proxyKeys.contains(key), let url = URLComponents(string:value), url.user != nil {
                values.insert(value)
                if let user = url.user, !user.isEmpty { values.insert(user) }
                if let password = url.password, !password.isEmpty { values.insert(password) }
            }
        }
        secrets = values.sorted { $0.count > $1.count }
    }
    var byteWindow: Int { 16384 + (secrets.map { $0.utf8.count }.max() ?? 0) }
    func text(_ input: String) -> String {
        var output = input
        for secret in secrets { output = output.replacingOccurrences(of:secret,with:"[redacted]") }
        // A pipe read can end partway through a secret. Do not publish its suffix.
        for secret in secrets {
            let pattern = Array(secret)
            var prefixes = [Int](repeating:0,count:pattern.count), matched = 0
            if pattern.count > 1 {
                for i in 1..<pattern.count {
                    var j = prefixes[i-1]
                    while j > 0 && pattern[i] != pattern[j] { j = prefixes[j-1] }
                    if pattern[i] == pattern[j] { j += 1 }; prefixes[i] = j
                }
            }
            for character in output {
                while matched > 0 && character != pattern[matched] { matched = prefixes[matched-1] }
                if character == pattern[matched] { matched += 1 }
                if matched == pattern.count { matched = prefixes[matched-1] }
            }
            if matched > 0 { output.removeLast(matched); output += "[redacted]" }
        }
        return output
    }
    func diagnostics(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var result: [String:JSONValue] = [:]
            for (key,value) in object {
                if ["error","errorMessage"].contains(key), case .string(let message) = value { result[key] = .string(text(message)) }
                else { result[key] = diagnostics(value) }
            }
            return .object(result)
        case .array(let array): return .array(array.map(diagnostics))
        default: return value
        }
    }
}
