import CryptoKit
import Foundation
import Network

public enum OAuthProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openRouter = "openrouter"
    case customPKCE = "custom_pkce"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter（一键浏览器登录）"
        case .customPKCE: return "自定义 OAuth 2.0 PKCE 平台"
        }
    }
}

public struct OAuthProviderConfig: Codable, Sendable, Equatable {
    public var kind: OAuthProviderKind
    public var authorizationURL: String
    public var tokenURL: String
    public var clientID: String
    public var scopes: String
    public var apiBaseURL: String
    public var model: String

    public init(
        kind: OAuthProviderKind = .openRouter,
        authorizationURL: String = "https://openrouter.ai/auth",
        tokenURL: String = "https://openrouter.ai/api/v1/auth/keys",
        clientID: String = "",
        scopes: String = "openid profile offline_access",
        apiBaseURL: String = "https://openrouter.ai/api/v1",
        model: String = "anthropic/claude-sonnet-4"
    ) {
        self.kind = kind
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.scopes = scopes
        self.apiBaseURL = apiBaseURL
        self.model = model
    }
}

public enum OAuthError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case listenerFailed(String)
    case cancelledOrTimedOut
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return "OAuth 配置无效：\(msg)"
        case .listenerFailed(let msg): return "无法启动本地 OAuth 回调监听：\(msg)"
        case .cancelledOrTimedOut: return "浏览器登录超时或已取消，请重试。"
        case .stateMismatch: return "OAuth 安全校验（state）不匹配，已中止登录。"
        case .missingAuthorizationCode: return "回调中缺少授权码（code）。"
        case .tokenExchangeFailed(let msg): return "换取登录令牌失败：\(msg)"
        }
    }
}

/// RFC 8252 native desktop OAuth 2.0 + PKCE manager using a loopback listener (`127.0.0.1`).
public enum OAuthSubscriptionManager {
    public static func keychainAccount(for kind: OAuthProviderKind) -> String {
        "oauth-token-\(kind.rawValue)"
    }

    public static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        return (verifier, challenge)
    }

    public static func buildAuthorizationURL(
        config: OAuthProviderConfig,
        callbackURL: String,
        codeChallenge: String,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(string: config.authorizationURL) else {
            throw OAuthError.invalidConfiguration("无效的授权地址：\(config.authorizationURL)")
        }

        switch config.kind {
        case .openRouter:
            components.queryItems = [
                URLQueryItem(name: "callback_url", value: callbackURL),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
        case .customPKCE:
            guard !config.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OAuthError.invalidConfiguration("自定义 OAuth 2.0 需要填写 Client ID")
            }
            var items = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: config.clientID),
                URLQueryItem(name: "redirect_uri", value: callbackURL),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
            let scope = config.scopes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !scope.isEmpty {
                items.append(URLQueryItem(name: "scope", value: scope))
            }
            components.queryItems = items
        }

        guard let url = components.url else {
            throw OAuthError.invalidConfiguration("无法构造授权 URL")
        }
        return url
    }

    public static func parseCallbackQuery(from requestLine: String) -> [String: String] {
        // Example: "GET /callback?code=abc&state=xyz HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return [:] }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let items = components.queryItems else {
            return [:]
        }
        var dict: [String: String] = [:]
        for item in items {
            if let value = item.value {
                dict[item.name] = value
            }
        }
        return dict
    }

    /// Runs the full browser OAuth PKCE sign-in flow and saves the resulting token to macOS Keychain.
    public static func signIn(
        config: OAuthProviderConfig,
        openURL: @escaping @Sendable (URL) -> Void
    ) async throws -> OAuthTokenBundle {
        let pkce = generatePKCE()
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let server = try LoopbackCallbackServer()
        let port = try await server.start()
        defer { server.stop() }

        let callbackURL = "http://127.0.0.1:\(port)/callback"
        let authURL = try buildAuthorizationURL(
            config: config,
            callbackURL: callbackURL,
            codeChallenge: pkce.challenge,
            state: state
        )

        openURL(authURL)

        let params = try await server.waitForCallback(timeoutSeconds: 180)
        if config.kind == .customPKCE, params["state"] != state {
            throw OAuthError.stateMismatch
        }
        if let err = params["error"] {
            throw OAuthError.tokenExchangeFailed(params["error_description"] ?? err)
        }
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.missingAuthorizationCode
        }

        let bundle = try await exchangeCodeForToken(
            config: config,
            code: code,
            codeVerifier: pkce.verifier,
            callbackURL: callbackURL
        )
        try KeychainStore.saveToken(bundle, account: keychainAccount(for: config.kind))
        return bundle
    }

    public static func refreshTokenIfNeeded(config: OAuthProviderConfig) async throws -> OAuthTokenBundle {
        let account = keychainAccount(for: config.kind)
        guard let current = KeychainStore.loadToken(account: account) else {
            throw OAuthError.tokenExchangeFailed("尚未登录，请先在设置中点击「浏览器登录」。")
        }
        if !current.isExpired {
            return current
        }
        guard config.kind == .customPKCE,
              let refreshToken = current.refreshToken,
              let tokenURL = URL(string: config.tokenURL) else {
            return current
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type=refresh_token",
            "refresh_token=\(urlEncodeForm(refreshToken))",
            "client_id=\(urlEncodeForm(config.clientID))"
        ].joined(separator: "&")
        request.httpBody = Data(form.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("刷新令牌失败：\(body.prefix(200))")
        }

        let refreshed = try decodeStandardTokenResponse(data, fallbackRefreshToken: refreshToken)
        try KeychainStore.saveToken(refreshed, account: account)
        return refreshed
    }

    public static func signOut(kind: OAuthProviderKind) {
        KeychainStore.delete(account: keychainAccount(for: kind))
    }

    // MARK: - Token Exchange

    private static func exchangeCodeForToken(
        config: OAuthProviderConfig,
        code: String,
        codeVerifier: String,
        callbackURL: String
    ) async throws -> OAuthTokenBundle {
        guard let tokenURL = URL(string: config.tokenURL) else {
            throw OAuthError.invalidConfiguration("无效的 Token 地址：\(config.tokenURL)")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"

        switch config.kind {
        case .openRouter:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: String] = [
                "code": code,
                "code_verifier": codeVerifier,
                "code_challenge_method": "S256"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                throw OAuthError.tokenExchangeFailed("OpenRouter 返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)：\(errBody.prefix(200))")
            }

            struct OpenRouterKeyResp: Decodable {
                let key: String
                let user_id: String?
            }
            let decoded = try JSONDecoder().decode(OpenRouterKeyResp.self, from: data)
            return OAuthTokenBundle(
                accessToken: decoded.key,
                refreshToken: nil,
                expiresAt: nil,
                accountLabel: decoded.user_id ?? "OpenRouter 账号"
            )

        case .customPKCE:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = [
                "grant_type=authorization_code",
                "code=\(urlEncodeForm(code))",
                "redirect_uri=\(urlEncodeForm(callbackURL))",
                "client_id=\(urlEncodeForm(config.clientID))",
                "code_verifier=\(urlEncodeForm(codeVerifier))"
            ].joined(separator: "&")
            request.httpBody = Data(form.utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                throw OAuthError.tokenExchangeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)：\(errBody.prefix(200))")
            }
            return try decodeStandardTokenResponse(data, fallbackRefreshToken: nil)
        }
    }

    private static func decodeStandardTokenResponse(_ data: Data, fallbackRefreshToken: String?) throws -> OAuthTokenBundle {
        struct StandardOAuthResp: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(StandardOAuthResp.self, from: data)
        let expiresAt = decoded.expires_in.map { Date().addingTimeInterval($0) }
        return OAuthTokenBundle(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? fallbackRefreshToken,
            expiresAt: expiresAt,
            accountLabel: "OAuth 订阅账号"
        )
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func urlEncodeForm(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }
}

/// Minimal loopback HTTP server for RFC 8252 OAuth callbacks (`127.0.0.1`).
private final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mailpilot.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var startResumed = false
    private var resolved = false

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        do {
            self.listener = try NWListener(using: params)
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startResumed else { return }
                switch state {
                case .ready:
                    self.startResumed = true
                    if let port = self.listener.port?.rawValue {
                        cont.resume(returning: port)
                    } else {
                        cont.resume(throwing: OAuthError.listenerFailed("无法获取监听端口"))
                    }
                case .failed(let err):
                    self.startResumed = true
                    cont.resume(throwing: OAuthError.listenerFailed(err.localizedDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeoutSeconds: UInt64) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
                    guard let self, !self.resolved else { return }
                    self.resolved = true
                    self.continuation?.resume(throwing: OAuthError.cancelledOrTimedOut)
                    self.continuation = nil
                }
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let requestText = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = requestText.components(separatedBy: "\r\n").first ?? ""
            let params = OAuthSubscriptionManager.parseCallbackQuery(from: firstLine)

            let html = """
            <!doctype html><html><meta charset="utf-8"><body style="font-family:-apple-system,sans-serif;text-align:center;padding:60px;">
            <h2>✅ MailPilot 登录授权成功</h2><p>可以关闭此浏览器标签页并返回 MailPilot。</p></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if !self.resolved {
                self.resolved = true
                self.continuation?.resume(returning: params)
                self.continuation = nil
            }
        }
    }
}
