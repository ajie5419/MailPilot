import Foundation

public enum AIServiceError: LocalizedError, Sendable {
    case invalidEndpoint(String)
    case httpError(statusCode: Int, body: String)
    case emptyResponse
    case incompleteStream(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let url):
            return "AI 配置或接口无效：\(url)"
        case .httpError(let code, let body):
            return "AI 请求失败（状态 \(code)）：\(body.prefix(240))"
        case .emptyResponse:
            return "AI 未返回有效内容。"
        case .incompleteStream(let reason):
            return "AI 回答不完整：\(reason)"
        }
    }
}

/// Unified AI router supporting:
/// 1. Local subscription CLIs (Claude Code / Codex / Gemini)
/// 2. Standard OAuth 2.0 PKCE browser sign-in (tokens persisted in macOS Keychain)
/// 3. Direct OpenAI-compatible API Key / local Ollama endpoints
public struct AIService: Sendable {
    public init() {}

    public func chat(
        config: AIConfig,
        systemPrompt: String,
        history: [AIChatMessage],
        userMessage: String,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let processedSystem = config.maskSensitiveData ? PrivacyMasker.mask(systemPrompt) : systemPrompt
        let processedUser = config.maskSensitiveData ? PrivacyMasker.mask(userMessage) : userMessage
        let processedHistory = history.map { msg in
            AIChatMessage(
                id: msg.id,
                role: msg.role,
                content: config.maskSensitiveData ? PrivacyMasker.mask(msg.content) : msg.content,
                createdAt: msg.createdAt
            )
        }

        switch config.authMode {
        case .chatGPT:
            return try await ChatGPTService.shared.chat(
                model: config.chatGPTModel ?? "", instructions: processedSystem,
                history: processedHistory, message: processedUser, onPartial: onPartial
            )
        case .subscriptionCLI:
            let combinedPrompt = buildCombinedPrompt(
                systemPrompt: processedSystem,
                history: processedHistory,
                userMessage: processedUser
            )
            return try await SubscriptionCLIBridge.runChat(
                provider: config.cliProvider,
                customBinaryPath: config.cliCustomPath,
                modelOverride: config.cliModelOverride,
                prompt: combinedPrompt,
                onPartial: onPartial
            )

        case .oauthPKCE:
            let tokenBundle = try await OAuthSubscriptionManager.refreshTokenIfNeeded(config: config.oauth)
            return try await callOpenAICompatible(
                baseURL: config.oauth.apiBaseURL,
                apiKey: tokenBundle.accessToken,
                model: config.oauth.model,
                systemPrompt: processedSystem,
                history: processedHistory,
                userMessage: processedUser,
                onPartial: onPartial
            )

        case .apiKey:
            return try await callOpenAICompatible(
                baseURL: config.baseURL,
                apiKey: config.apiKey,
                model: config.model,
                systemPrompt: processedSystem,
                history: processedHistory,
                userMessage: processedUser,
                onPartial: onPartial
            )
        }
    }

    private func buildCombinedPrompt(
        systemPrompt: String,
        history: [AIChatMessage],
        userMessage: String
    ) -> String {
        var sections: [String] = []
        sections.append("### 系统上下文\n\(systemPrompt)")
        if !history.isEmpty {
            let transcript = history.map { msg -> String in
                let speaker = msg.role == .user ? "用户" : "助手"
                return "\(speaker)：\(msg.content)"
            }.joined(separator: "\n\n")
            sections.append("### 对话历史\n\(transcript)")
        }
        sections.append("### 当前请求\n\(userMessage)")
        return sections.joined(separator: "\n\n")
    }

    private func callOpenAICompatible(
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        history: [AIChatMessage],
        userMessage: String,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw AIServiceError.invalidEndpoint(baseURL)
        }

        var payloadMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history {
            payloadMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }
        payloadMessages.append(["role": "user", "content": userMessage])

        let requestBody: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "temperature": 0.3,
            "stream": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            var errText = ""
            for try await line in bytes.lines {
                errText += line
                if errText.count > 240 { break }
            }
            throw AIServiceError.httpError(statusCode: http.statusCode, body: errText)
        }

        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            struct APIError: Decodable { let message: String? }
            let choices: [Choice]?
            let error: APIError?
        }

        var accumulated = ""
        var sawDone = false
        var finishReason: String?
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
                sawDone = true
                break
            }
            if let data = payload.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
                if let errMsg = chunk.error?.message, !errMsg.isEmpty {
                    throw AIServiceError.incompleteStream(reason: errMsg)
                }
                if let reason = chunk.choices?.first?.finish_reason, !reason.isEmpty {
                    finishReason = reason
                }
                if let piece = chunk.choices?.first?.delta?.content {
                    accumulated += piece
                    onPartial?(accumulated)
                }
            }
        }

        if let reason = finishReason, reason == "length" || reason == "content_filter" {
            throw AIServiceError.incompleteStream(reason: "回答被截断（finish_reason=\(reason)）")
        }
        guard sawDone || finishReason == "stop" else {
            throw AIServiceError.incompleteStream(reason: "流式连接在收到结束标记前中断")
        }

        let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        return finalText
    }
}
