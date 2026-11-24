import Foundation

public enum SubscriptionCLIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case antigravity = "agy"
    case codex = "codex"
    case claudeCode = "claude"
    case gemini = "gemini"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity 订阅（agy CLI）"
        case .codex: return "ChatGPT 订阅（Codex CLI）"
        case .claudeCode: return "Claude 订阅（Claude Code CLI）"
        case .gemini: return "Google 订阅（Gemini CLI）"
        }
    }

    public var shortBadge: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "ChatGPT 订阅"
        case .claudeCode: return "Claude 订阅"
        case .gemini: return "Gemini 订阅"
        }
    }

    public var loginCommandHint: String {
        switch self {
        case .antigravity: return "agy"
        case .codex: return "codex login"
        case .claudeCode: return "claude login"
        case .gemini: return "gemini"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .antigravity:
            return ["flash", "flash_lite", "pro"]
        case .codex:
            return ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"]
        case .claudeCode:
            return ["opus", "sonnet", "haiku", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .gemini:
            return ["gemini-2.5-pro", "gemini-2.5-flash"]
        }
    }
}

public struct SubscriptionCLIStatus: Sendable {
    public let provider: SubscriptionCLIProvider
    public let executablePath: String?

    public var isInstalled: Bool { executablePath != nil }
}

/// Bridges MailPilot AI requests to official local subscription CLIs (`claude`, `codex`, `gemini`)
/// so users reuse their existing Claude Pro/Max, ChatGPT Plus/Pro, or Gemini subscriptions directly.
public enum SubscriptionCLIBridge {
    /// Standard search directories because macOS GUI apps inherit a minimal PATH without Homebrew or `~/.local/bin`.
    public static func searchPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin"
        ]
    }

    public static func resolveExecutable(
        for provider: SubscriptionCLIProvider,
        customPath: String = ""
    ) -> String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        let binaryName = provider.rawValue
        for dir in searchPaths() {
            let candidate = "\(dir)/\(binaryName)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func detectAll() -> [SubscriptionCLIStatus] {
        SubscriptionCLIProvider.allCases.map { provider in
            SubscriptionCLIStatus(
                provider: provider,
                executablePath: resolveExecutable(for: provider)
            )
        }
    }

    public static func runChat(
        provider: SubscriptionCLIProvider,
        customBinaryPath: String,
        modelOverride: String,
        prompt: String,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let execPath = resolveExecutable(for: provider, customPath: customBinaryPath) else {
            throw AIServiceError.invalidEndpoint(
                "未在本机找到 \(provider.displayName) 可执行文件（\(provider.rawValue)）。请先安装并在终端运行 `\(provider.loginCommandHint)` 完成订阅登录。"
            )
        }

        let trimmedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let tempOutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailpilot-cli-out-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempOutURL) }

        let arguments: [String]
        switch provider {
        case .antigravity:
            var args = [
                "-p",
                "--output-format", "stream-json",
                "--disable-slash-commands",
                "--effort", "low"
            ]
            if !trimmedModel.isEmpty {
                args += ["--model", trimmedModel]
            }
            args.append(prompt)
            arguments = args
        case .claudeCode:
            // Skip MCP servers, slash commands, tools, and session persistence for minimal cold-start latency.
            var args = [
                "-p",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--effort", "low",
                "--tools", ""
            ]
            if !trimmedModel.isEmpty {
                args += ["--model", trimmedModel]
            }
            arguments = args
        case .codex:
            // `--ignore-user-config` skips heavy MCP servers / hooks / plugins in config.toml while keeping CODEX_HOME auth.
            var args = [
                "exec",
                "--ignore-user-config",
                "--ephemeral",
                "--skip-git-repo-check",
                "--json",
                "-s", "read-only",
                "-C", "/tmp",
                "-c", "model_reasoning_effort=\"low\"",
                "-o", tempOutURL.path
            ]
            if !trimmedModel.isEmpty {
                args += ["-m", trimmedModel]
            }
            args.append("-")
            arguments = args
        case .gemini:
            var args = ["-p", prompt]
            if !trimmedModel.isEmpty {
                args += ["-m", trimmedModel]
            }
            arguments = args
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = (searchPaths() + [existingPath]).joined(separator: ":")
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    if provider != .gemini && provider != .antigravity {
                        if let data = prompt.data(using: .utf8) {
                            stdinPipe.fileHandleForWriting.write(data)
                        }
                    }
                    try? stdinPipe.fileHandleForWriting.close()

                    // Stream stdout line-by-line for real-time UI updates.
                    var accumulated = ""
                    var lineBuffer = Data()
                    let readHandle = stdoutPipe.fileHandleForReading

                    while true {
                        let chunk = readHandle.availableData
                        if chunk.isEmpty { break }
                        lineBuffer.append(chunk)

                        while let nl = lineBuffer.firstIndex(of: 0x0A) {
                            let lineData = lineBuffer.subdata(in: 0..<nl)
                            lineBuffer.removeSubrange(0...nl)
                            if let line = String(data: lineData, encoding: .utf8) {
                                Self.consumeStreamLine(
                                    line: line,
                                    provider: provider,
                                    accumulated: &accumulated,
                                    onPartial: onPartial
                                )
                            }
                        }
                    }
                    if !lineBuffer.isEmpty, let tail = String(data: lineBuffer, encoding: .utf8) {
                        Self.consumeStreamLine(
                            line: tail,
                            provider: provider,
                            accumulated: &accumulated,
                            onPartial: onPartial
                        )
                    }

                    process.waitUntilExit()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus == 0 {
                        if provider == .codex,
                           let fileText = try? String(contentsOf: tempOutURL, encoding: .utf8),
                           !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let finalText = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
                            onPartial?(finalText)
                            continuation.resume(returning: finalText)
                            return
                        }
                        let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        if finalText.isEmpty {
                            continuation.resume(throwing: AIServiceError.emptyResponse)
                        } else {
                            continuation.resume(returning: finalText)
                        }
                    } else {
                        let errText = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let detail = errText.isEmpty ? accumulated : errText
                        continuation.resume(
                            throwing: AIServiceError.httpError(
                                statusCode: Int(process.terminationStatus),
                                body: detail.isEmpty ? "请先在终端运行 `\(provider.loginCommandHint)` 登录订阅账号。" : detail
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: AIServiceError.httpError(statusCode: -1, body: error.localizedDescription))
                }
            }
        }
    }

    private static func consumeStreamLine(
        line: String,
        provider: SubscriptionCLIProvider,
        accumulated: inout String,
        onPartial: (@Sendable (String) -> Void)?
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if provider == .gemini {
            accumulated += (accumulated.isEmpty ? "" : "\n") + trimmed
            onPartial?(accumulated)
            return
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        switch provider {
        case .antigravity:
            // Support stream-json delta / assistant message / final result events from `agy -p --output-format stream-json`
            if let event = json["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                accumulated += text
                onPartial?(accumulated)
                return
            }
            if let delta = json["delta"] as? String, !delta.isEmpty {
                accumulated += delta
                onPartial?(accumulated)
                return
            }
            if let type = json["type"] as? String {
                if type == "assistant",
                   let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    let joined = content.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty {
                        accumulated = joined
                        onPartial?(accumulated)
                        return
                    }
                }
                if type == "result", let resultText = json["result"] as? String, !resultText.isEmpty {
                    accumulated = resultText
                    onPartial?(accumulated)
                    return
                }
            }
            if let text = json["text"] as? String, !text.isEmpty {
                accumulated += text
                onPartial?(accumulated)
            }

        case .claudeCode:
            // Stream deltas from `--include-partial-messages`
            if let event = json["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                accumulated += text
                onPartial?(accumulated)
                return
            }
            if let type = json["type"] as? String, type == "result",
               let resultText = json["result"] as? String, !resultText.isEmpty {
                accumulated = resultText
                onPartial?(accumulated)
            }

        case .codex:
            // Handle incremental delta or completed agent_message items from `codex exec --json`
            if let delta = json["delta"] as? String, !delta.isEmpty {
                accumulated += delta
                onPartial?(accumulated)
                return
            }
            if let msg = json["msg"] as? [String: Any],
               let delta = msg["delta"] as? String, !delta.isEmpty {
                accumulated += delta
                onPartial?(accumulated)
                return
            }
            if let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "agent_message" || itemType == "message" {
                if let text = item["text"] as? String, !text.isEmpty {
                    accumulated = text
                    onPartial?(accumulated)
                } else if let contentArr = item["content"] as? [[String: Any]] {
                    let joined = contentArr.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty {
                        accumulated = joined
                        onPartial?(accumulated)
                    }
                }
            }

        case .gemini:
            break
        }
    }

    /// Launches macOS Terminal.app and runs the official login command for the selected subscription CLI.
    public static func openTerminalForLogin(provider: SubscriptionCLIProvider) {
        let cmd = provider.loginCommandHint
        let script = """
        tell application "Terminal"
            activate
            do script "\(cmd)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
