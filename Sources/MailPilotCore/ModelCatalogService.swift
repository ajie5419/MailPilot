import Foundation

public struct ModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

/// Dynamically discovers available models instead of relying on hardcoded stale lists:
/// - Codex CLI: reads `~/.codex/models_cache.json` (filtered by `visibility == "list"`, sorted by `priority`)
/// - Claude Code CLI: uses official evergreen aliases (`opus`, `sonnet`, `haiku`) + latest IDs
/// - OAuth / API Key / Ollama: queries `{baseURL}/models` (or Ollama `/api/tags`)
public enum ModelCatalogService {
    public static func loadCodexCachedModels(from fileURL: URL? = nil) -> [ModelOption] {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parseCodexModelsCache(data)
    }

    public static func parseCodexModelsCache(_ data: Data) -> [ModelOption] {
        struct CacheFile: Decodable {
            struct Entry: Decodable {
                let slug: String
                let display_name: String?
                let visibility: String?
                let priority: Int?
            }
            let models: [Entry]
        }
        guard let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return []
        }
        let visible = decoded.models
            .filter { ($0.visibility ?? "list") == "list" }
            .sorted { ($0.priority ?? 999) < ($1.priority ?? 999) }
        return visible.map { entry in
            ModelOption(id: entry.slug, displayName: entry.display_name ?? entry.slug)
        }
    }

    public static func loadAntigravityModels(customPath: String = "") async -> [ModelOption] {
        guard let execPath = SubscriptionCLIBridge.resolveExecutable(for: .antigravity, customPath: customPath) else {
            return []
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = ["models"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (SubscriptionCLIBridge.searchPaths() + [env["PATH"] ?? ""]).joined(separator: ":")
                process.environment = env

                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0,
                          let text = String(data: data, encoding: .utf8) else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: parseAntigravityModelsOutput(text))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public static func parseAntigravityModelsOutput(_ output: String) -> [ModelOption] {
        var options: [ModelOption] = []
        var seen: Set<String> = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("NAME") || line.hasPrefix("MODEL") || line.hasPrefix("---") || line.hasPrefix("Available") {
                continue
            }
            // Strip leading bullet/marker if present
            let cleaned = line.replacingOccurrences(of: #"^[\*\-\•\s]+"#, with: "", options: .regularExpression)
            let tokens = cleaned.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard let first = tokens.first else { continue }
            let id = String(first)
            guard id.count >= 2, !seen.contains(id) else { continue }
            seen.insert(id)
            let rest = cleaned.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
            let label = rest.isEmpty ? id : "\(id) · \(rest.prefix(36))"
            options.append(ModelOption(id: id, displayName: label))
        }
        return options
    }

    public static func fetchAvailableModels(config: AIConfig) async -> [ModelOption] {
        switch config.authMode {
        case .chatGPT:
            return (try? await ChatGPTService.shared.models()) ?? []
        case .subscriptionCLI:
            switch config.cliProvider {
            case .antigravity:
                let dynamic = await loadAntigravityModels(customPath: config.cliCustomPath)
                if !dynamic.isEmpty { return dynamic }
                return config.cliProvider.suggestedModels.map { ModelOption(id: $0) }
            case .codex:
                let cached = loadCodexCachedModels()
                if !cached.isEmpty { return cached }
                return config.cliProvider.suggestedModels.map { ModelOption(id: $0) }
            case .claudeCode:
                return [
                    ModelOption(id: "opus", displayName: "Opus（自动最新）"),
                    ModelOption(id: "sonnet", displayName: "Sonnet（自动最新）"),
                    ModelOption(id: "haiku", displayName: "Haiku（自动最新）"),
                    ModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
                    ModelOption(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
                    ModelOption(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5")
                ]
            case .gemini:
                return config.cliProvider.suggestedModels.map { ModelOption(id: $0) }
            }

        case .oauthPKCE:
            let token = KeychainStore.loadToken(
                account: OAuthSubscriptionManager.keychainAccount(for: config.oauth.kind)
            )?.accessToken ?? ""
            let fetched = await fetchRemoteModels(baseURL: config.oauth.apiBaseURL, apiKey: token)
            if !fetched.isEmpty { return fetched }
            return [
                ModelOption(id: "anthropic/claude-sonnet-5-5"),
                ModelOption(id: "anthropic/claude-opus-5-5"),
                ModelOption(id: "openai/gpt-6.1-sol"),
                ModelOption(id: "google/gemini-2.5-pro")
            ]

        case .apiKey:
            let fetched = await fetchRemoteModels(baseURL: config.baseURL, apiKey: config.apiKey)
            if !fetched.isEmpty { return fetched }
            if config.baseURL.contains("deepseek") {
                return [ModelOption(id: "deepseek-chat"), ModelOption(id: "deepseek-reasoner")]
            }
            return [ModelOption(id: config.model)]
        }
    }

    private static func fetchRemoteModels(baseURL: String, apiKey: String) async -> [ModelOption] {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        // Try OpenAI-compatible `/models`
        if let url = URL(string: "\(base)/models") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if let (data, resp) = try? await URLSession.shared.data(for: request),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                struct ModelsResp: Decodable {
                    struct Item: Decodable {
                        let id: String
                        let name: String?
                    }
                    let data: [Item]
                }
                if let decoded = try? JSONDecoder().decode(ModelsResp.self, from: data),
                   !decoded.data.isEmpty {
                    return decoded.data.prefix(60).map { ModelOption(id: $0.id, displayName: $0.name ?? $0.id) }
                }
            }
        }

        // Fallback for local Ollama `/api/tags`
        if base.contains("localhost:11434") || base.contains("127.0.0.1:11434"),
           let url = URL(string: "http://localhost:11434/api/tags") {
            if let (data, resp) = try? await URLSession.shared.data(from: url),
               let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                struct OllamaTags: Decodable {
                    struct Tag: Decodable { let name: String }
                    let models: [Tag]
                }
                if let decoded = try? JSONDecoder().decode(OllamaTags.self, from: data) {
                    return decoded.models.map { ModelOption(id: $0.name) }
                }
            }
        }

        return []
    }
}
