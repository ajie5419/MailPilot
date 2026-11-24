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
    public struct ContextBudget: Sendable, Equatable {
        public let maxHistoryMessages: Int
        public let maxHistoryChars: Int
        public let maxMessageChars: Int

        public init(
            maxHistoryMessages: Int = 12,
            maxHistoryChars: Int = 12_000,
            maxMessageChars: Int = 4_000
        ) {
            self.maxHistoryMessages = max(0, maxHistoryMessages)
            self.maxHistoryChars = max(0, maxHistoryChars)
            self.maxMessageChars = max(0, maxMessageChars)
        }

        public static let `default` = ContextBudget()
    }

    public struct PreparedHistory: Sendable {
        public let messages: [AIChatMessage]
        public let droppedCount: Int

        public init(messages: [AIChatMessage], droppedCount: Int) {
            self.messages = messages
            self.droppedCount = droppedCount
        }
    }

    public let contextBudget: ContextBudget

    public init(contextBudget: ContextBudget = .default) {
        self.contextBudget = contextBudget
    }

    /// Filters error/empty placeholders and keeps a bounded recent window of conversation history
    /// so long threads stay within context limits and avoid unnecessary token usage.
    public static func prepareHistory(
        _ history: [AIChatMessage],
        budget: ContextBudget = .default
    ) -> PreparedHistory {
        let validMessages = history.filter {
            !$0.isError && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !validMessages.isEmpty else {
            return PreparedHistory(messages: [], droppedCount: 0)
        }
        guard budget.maxHistoryMessages > 0, budget.maxHistoryChars > 0 else {
            return PreparedHistory(messages: [], droppedCount: validMessages.count)
        }

        var selectedReversed: [AIChatMessage] = []
        selectedReversed.reserveCapacity(min(validMessages.count, budget.maxHistoryMessages))
        var usedChars = 0

        for msg in validMessages.reversed() {
            if selectedReversed.count >= budget.maxHistoryMessages {
                break
            }
            let clipped = clipContent(msg.content, maxChars: budget.maxMessageChars)
            let cost = clipped.count
            if usedChars + cost <= budget.maxHistoryChars {
                selectedReversed.append(
                    AIChatMessage(
                        id: msg.id,
                        role: msg.role,
                        content: clipped,
                        createdAt: msg.createdAt,
                        isError: false
                    )
                )
                usedChars += cost
            } else if selectedReversed.isEmpty {
                let fitted = clipContent(clipped, maxChars: budget.maxHistoryChars)
                selectedReversed.append(
                    AIChatMessage(
                        id: msg.id,
                        role: msg.role,
                        content: fitted,
                        createdAt: msg.createdAt,
                        isError: false
                    )
                )
                break
            } else {
                break
            }
        }

        let kept = Array(selectedReversed.reversed())
        let dropped = max(0, validMessages.count - kept.count)
        return PreparedHistory(messages: kept, droppedCount: dropped)
    }

    private static func clipContent(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0, text.count > maxChars else { return text }
        let suffix = "\n…（已截断）"
        if maxChars <= suffix.count {
            return String(text.prefix(maxChars))
        }
        return String(text.prefix(maxChars - suffix.count)) + suffix
    }

    public func chat(
        config: AIConfig,
        systemPrompt: String,
        history: [AIChatMessage],
        userMessage: String,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let prepared = Self.prepareHistory(history, budget: contextBudget)
        let effectiveSystemPrompt: String
        if prepared.droppedCount > 0 {
            effectiveSystemPrompt = systemPrompt + "\n\n（注：为控制上下文长度，已省略更早的 \(prepared.droppedCount) 条历史对话，仅保留最近记录。）"
        } else {
            effectiveSystemPrompt = systemPrompt
        }

        let processedSystem = config.maskSensitiveData ? PrivacyMasker.mask(effectiveSystemPrompt) : effectiveSystemPrompt
        let processedUser = config.maskSensitiveData ? PrivacyMasker.mask(userMessage) : userMessage
        let processedHistory = prepared.messages.map { msg in
            AIChatMessage(
                id: msg.id,
                role: msg.role,
                content: config.maskSensitiveData ? PrivacyMasker.mask(msg.content) : msg.content,
                createdAt: msg.createdAt,
                isError: msg.isError
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
                let speaker: String
                switch msg.role {
                case .user: speaker = "用户"
                case .assistant: speaker = "助手"
                case .system: speaker = "系统"
                }
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
