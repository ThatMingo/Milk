import Foundation
import Darwin

/// Host-owned inputs only. Runtime credentials and Milk worker environments never merge.
enum PiEnvironment {
    static let localeKeys: Set<String> = ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LC_COLLATE", "LC_NUMERIC", "LC_TIME", "TZ"]
    static let proxyKeys: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"]
    // Pi 1.4 provider contract, not a wildcard over the user's credentials.
    static let providerKeys: Set<String> = Set("""
    ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID ANTHROPIC_IDENTITY_TOKEN_FILE ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID
    ANT_LING_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY NVIDIA_API_KEY GEMINI_API_KEY COPILOT_GITHUB_TOKEN MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY ZAI_CODING_CN_API_KEY OPENCODE_API_KEY RADIUS_API_KEY TYPESAFE_API_KEY HF_TOKEN FIREWORKS_API_KEY TOGETHER_API_KEY BASETEN_API_KEY KIMI_API_KEY META_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY MOONSHOT_API_KEY QWEN_TOKEN_PLAN_API_KEY QWEN_TOKEN_PLAN_CN_API_KEY XIAOMI_API_KEY XIAOMI_TOKEN_PLAN_CN_API_KEY XIAOMI_TOKEN_PLAN_AMS_API_KEY XIAOMI_TOKEN_PLAN_SGP_API_KEY
    AZURE_OPENAI_API_KEY AZURE_OPENAI_BASE_URL AZURE_OPENAI_RESOURCE_NAME AZURE_OPENAI_DEPLOYMENT_NAME_MAP AZURE_OPENAI_API_VERSION
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK AWS_REGION AWS_DEFAULT_REGION AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_SDK_LOAD_CONFIG AWS_EC2_METADATA_DISABLED AWS_EC2_METADATA_V1_DISABLED AWS_CA_BUNDLE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
    CLOUDFLARE_API_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_GATEWAY_ID GOOGLE_CLOUD_API_KEY GOOGLE_CLOUD_PROJECT GCLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_APPLICATION_CREDENTIALS
    """.split(whereSeparator: \.isWhitespace).map(String.init))
    static let runtimeKeys: Set<String> = ["PI_PACKAGE_DIR", "PI_CACHE_RETENTION", "PI_TELEMETRY", "PI_CODEMODE_MAX_WORKERS", "PI_CODING_AGENT_SESSION_DIR", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"]
    static func forbidden(_ key: String) -> Bool {
        key.hasPrefix("DYLD_") || key.hasPrefix("LD_") || key.hasPrefix("GIT_") ||
        key.hasPrefix("MILK_") || key.hasPrefix("BASH_FUNC_") ||
        ["ENV", "BASH_ENV", "ZDOTDIR", "SHELLOPTS", "BASHOPTS", "CDPATH", "IFS", "NODE_OPTIONS", "NODE_PATH", "BUN_OPTIONS", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "PERL5OPT", "RUBYOPT"].contains(key)
    }
    private static func valid(_ key: String, _ value: String) -> Bool {
        !value.utf8.contains(0) && key.range(of:"^[A-Za-z_][A-Za-z0-9_]*$",options:.regularExpression) != nil
    }
    private static func explicitAllowed(_ key: String) -> Bool {
        let milkAuthority = key.hasPrefix("MILK_PI_") || key.hasPrefix("MILK_SANDBOX_") || key.hasPrefix("MILK_NATIVE_") || ["MILK_PERMISSION_MODE","MILK_PREVIEW_DISCOVERY"].contains(key)
        return !milkAuthority && (!forbidden(key) || key.hasPrefix("MILK_"))
    }
    private static func base(home: URL, temporary: URL, support: [URL]) -> [String:String] {
        var result = SandboxEnvironment.execution(home:home,temporary:temporary,support:support)
        result["PI_OFFLINE"] = "1"; result["PI_SKIP_VERSION_CHECK"] = "1"
        return result
    }
    /// No ambient dictionary is accepted by the Milk-owned executor/worker boundary.
    static func executor(work: URL, support: [URL], toolchain: SandboxToolchainEnvironment? = nil) -> [String:String] {
        var result = base(home:work,temporary:work,support:support)
        if let directory = toolchain?.developerDirectory { result["DEVELOPER_DIR"] = directory.path }
        result["PI_CODING_AGENT_DIR"] = work.appendingPathComponent("profile").path
        return result
    }
    static func runtime(source: [String:String], explicit: [String:String], profile: AgentDataProfile, support: [URL]) throws -> [String:String] {
        guard support.allSatisfy({ !$0.path.contains(":") && !$0.path.utf8.contains(0) }) else {
            throw AgentError.message("The selected runtime support directory cannot be represented safely in PATH.")
        }
        for key in ["HOME","TMPDIR"] {
            if let value = source[key], !value.hasPrefix("/") || value.utf8.contains(0) {
                throw AgentError.message("Pi \(key) must be an absolute local path without NUL characters.")
            }
        }
        let home = source["HOME"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let temporary = source["TMPDIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.temporaryDirectory
        var result = base(home:home,temporary:temporary,support:support)
        let references = try referencedVariables(profile:profile.directory)
        let keys = localeKeys.union(proxyKeys).union(providerKeys).union(runtimeKeys).union(references)
        for key in keys where !forbidden(key) { if let value = source[key], valid(key,value) { result[key] = value } }
        // Explicit app-owned launch overrides are not model-supplied environment data.
        // Keep opaque fixture/selected-launcher inputs, but never startup injection or Milk authority.
        for (key,value) in explicit where valid(key,value) && explicitAllowed(key) && key != "PATH" && key != "HOME" && key != "TMPDIR" && key != "PI_CODING_AGENT_DIR" && key != "SHELL" && key != "DEVELOPER_DIR" { result[key] = value }
        result["PATH"] = SandboxEnvironment.path(support:support,ambient:source["PATH"])
        let toolchain = try SandboxToolchainEnvironment(source:source)
        if let directory = toolchain.developerDirectory { result["DEVELOPER_DIR"] = directory.path }
        result["PI_CODING_AGENT_DIR"] = profile.directory.path
        result["PI_OFFLINE"] = "1"; result["PI_SKIP_VERSION_CHECK"] = "1"
        return result
    }
    static func probe(source: [String:String], explicit: [String:String] = [:], work: URL, support: [URL], toolchain: SandboxToolchainEnvironment? = nil) -> [String:String] {
        var result = executor(work:work,support:support)
        for key in localeKeys { if let value = source[key], valid(key,value) { result[key] = value } }
        result["PATH"] = SandboxEnvironment.path(support:support,ambient:source["PATH"])
        for (key,value) in explicit where valid(key,value) && explicitAllowed(key) && !providerKeys.contains(key) && !proxyKeys.contains(key) && !runtimeKeys.contains(key) && !["PATH","HOME","TMPDIR","PI_CODING_AGENT_DIR","SHELL","DEVELOPER_DIR"].contains(key) { result[key] = value }
        if let developer = toolchain?.developerDirectory { result["DEVELOPER_DIR"] = developer.path }
        if let package = source["PI_PACKAGE_DIR"], package.hasPrefix("/"), !package.utf8.contains(0) { result["PI_PACKAGE_DIR"] = package }
        result["PI_OFFLINE"] = "1"; result["PI_SKIP_VERSION_CHECK"] = "1"
        return result
    }
    /// Only the selected user profile can declare additional provider/MCP environment references.
    /// Project-controlled configuration never selects extra ambient host credentials.
    static func referencedVariables(profile: URL) throws -> Set<String> {
        var names: Set<String> = []
        let expression = try NSRegularExpression(pattern:#"(?<!\$)\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"#)
        func visit(_ value: Any) {
            if let string = value as? String {
                for match in expression.matches(in:string,range:NSRange(string.startIndex...,in:string)) {
                    for i in [1,2] { if let range = Range(match.range(at:i),in:string) { names.insert(String(string[range])) } }
                }
            } else if let object = value as? [String:Any] { object.values.forEach(visit) }
            else if let array = value as? [Any] { array.forEach(visit) }
        }
        for name in ["models.json", "mcp.json"] {
            let file = profile.appendingPathComponent(name)
            var entry = stat()
            if lstat(file.path,&entry) < 0 { if errno == ENOENT { continue }; throw SandboxPathError.inaccessible }
            // NONBLOCK prevents named pipes/devices from blocking Milk during config admission.
            let fd = open(file.path,O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw AgentError.message("Pi \(name) could not be opened safely.") }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
            var opened = stat()
            guard fstat(fd,&opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                  try SandboxPathResolver().resolve(file).finalIdentity == SandboxFileIdentity(opened) else {
                throw AgentError.message("Pi \(name) must resolve to a stable regular configuration file.")
            }
            let data = try handle.read(upToCount:4 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 4 * 1024 * 1024 else { throw AgentError.message("Pi provider configuration is too large to validate its environment references.") }
            let object: Any
            do { object = try JSONSerialization.jsonObject(with:data,options:[.json5Allowed]) }
            catch { throw AgentError.message("Pi \(name) is not valid JSON/JSON5. Correct its environment declarations before starting Pi.") }
            // Only documented authentication interpolation fields admit host variables.
            // Model IDs/descriptions and server-provided metadata confer no authority.
            if name == "models.json", let providers = (object as? [String:Any])?["providers"] as? [String:[String:Any]] {
                func authFields(_ value: [String:Any]) {
                    if let key = value["apiKey"] { visit(key) }
                    if let headers = value["headers"] { visit(headers) }
                }
                for provider in providers.values {
                    authFields(provider)
                    for model in provider["models"] as? [[String:Any]] ?? [] { authFields(model) }
                    for model in (provider["modelOverrides"] as? [String:[String:Any]] ?? [:]).values { authFields(model) }
                }
            }
            if name == "mcp.json", let servers = (object as? [String:Any])?["mcpServers"] as? [String:[String:Any]] {
                for server in servers.values {
                    if let env = server["env"] { visit(env) }
                    if let headers = server["headers"] { visit(headers) }
                    if let secret = (server["oauth"] as? [String:Any])?["clientSecret"] { visit(secret) }
                }
            }
        }
        return names
    }
}
