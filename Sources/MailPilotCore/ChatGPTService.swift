import Foundation
import CryptoKit

public struct ChatGPTAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let signedIn: Bool
    public let planEnabled: Bool
}

struct ChatGPTRegistration: Codable, Sendable {
    var id: String
    var subject: String
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var scopes: [String]

    var account: ChatGPTAccount {
        ChatGPTAccount(id: id, label: "\(email ?? "ChatGPT 账号") · \(id.suffix(6))",
                       signedIn: accessToken != nil, planEnabled: scopes.contains(ChatGPTProtocol.permission))
    }
}

struct ChatGPTVault: Codable, Sendable {
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var selectedID: String?
    var registrations: [ChatGPTRegistration] = []
}

protocol ChatGPTVaultStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct ChatGPTKeychainStore: ChatGPTVaultStore {
    func read() throws -> Data? { try KeychainStore.loadChecked(account: "chatgpt-direct-v1") }
    func write(_ data: Data) throws { try KeychainStore.save(data, account: "chatgpt-direct-v1") }
}

private final class ChatGPTSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // OAuth credentials must never follow a redirect to a different endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Owns an independent OAuth registration; never reads Codex credentials or launches a process.
public actor ChatGPTService {
    public static let shared = ChatGPTService()
    private let store: any ChatGPTVaultStore
    private let session: URLSession
    private var vault: ChatGPTVault?
    private var generation = 0
    private var signingIn = false
    private var refreshTask: (id: UUID, task: Task<ChatGPTRegistration, Error>)?
    private var chats: [UUID: Task<String, Error>] = [:]

    init(store: any ChatGPTVaultStore = ChatGPTKeychainStore(), session: URLSession? = nil) {
        self.store = store
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: ChatGPTSessionDelegate(), delegateQueue: nil)
        }
    }

    private func load() throws -> ChatGPTVault {
        if let vault { return vault }
        let value = try store.read().map { try JSONDecoder().decode(ChatGPTVault.self, from: $0) } ?? ChatGPTVault()
        try save(value)
        return value
    }

    private func save(_ value: ChatGPTVault) throws {
        try store.write(JSONEncoder().encode(value))
        vault = value
    }

    public func accounts() throws -> [ChatGPTAccount] { try load().registrations.map(\.account) }
    public func selectedAccount() throws -> ChatGPTAccount? {
        let value = try load()
        return value.registrations.first { $0.id == value.selectedID }?.account
    }

    public func selectAccount(_ id: String) throws {
        guard !signingIn else { throw ChatGPTError.message("请先完成或取消当前登录。") }
        var value = try load()
        guard value.registrations.contains(where: { $0.id == id }) else { return }
        cancelRequests()
        value.selectedID = id
        try save(value)
    }

    private func cancelRequests() {
        generation += 1
        refreshTask?.task.cancel(); refreshTask = nil
        chats.values.forEach { $0.cancel() }; chats.removeAll()
    }

    public func signIn(newAccount: Bool, openURL: @escaping @Sendable (URL) -> Void) async throws {
        guard !signingIn else { throw ChatGPTError.message("已有登录正在进行。") }
        signingIn = true
        defer { signingIn = false }
        cancelRequests()
        let epoch = generation
        let current = try load()
        let existing = newAccount ? nil : current.registrations.first { $0.id == current.selectedID }
        let verifier = try ChatGPTProtocol.random()
        let challenge = OAuthSubscriptionManager.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try ChatGPTProtocol.random()
        let nonce = try ChatGPTProtocol.random()
        let callback = try ChatGPTCallbackServer(state: state)
        defer { callback.cancel() }
        let port = try await callback.start()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        try Task.checkCancellation()
        openURL(ChatGPTProtocol.authorizationURL(hostID: current.hostID, redirect: redirect, state: state,
                    nonce: nonce, challenge: challenge, registration: existing))
        let params = try await callback.wait()
        let id = try ChatGPTProtocol.clientID(callback: params, expectedState: state, existingID: existing?.id)
        guard let code = params["code"], !code.isEmpty else { throw ChatGPTError.message("授权未返回登录码。") }
        let tokens = try await tokenRequest(["grant_type": "authorization_code", "client_id": id,
            "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": ChatGPTProtocol.resource])
        guard let idToken = tokens.id_token else { throw ChatGPTError.message("授权缺少身份凭据，未保存登录信息。") }
        let keys = try await fetch(URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/jwks.json")!))
        let identity = try ChatGPTIDToken.verify(idToken, keys: keys, clientID: id, nonce: nonce)
        if let existing, existing.subject != identity.subject {
            throw ChatGPTError.message("登录账号与已保存的账号不一致，请使用添加账号。")
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        var value = try load()
        let registration = ChatGPTRegistration(id: id, subject: identity.subject, email: identity.email,
            accessToken: tokens.access_token, refreshToken: tokens.refresh_token, idToken: idToken,
            expiresAt: Date().addingTimeInterval(tokens.expires_in), scopes: tokens.scope?.split(separator: " ").map(String.init) ?? [])
        if let index = value.registrations.firstIndex(where: { $0.id == id }) {
            guard value.registrations[index].subject == identity.subject else { throw ChatGPTError.message("注册账号不一致。") }
            value.registrations[index] = registration
        } else { value.registrations.append(registration) }
        value.selectedID = id
        try save(value)
    }

    /// Local logout always completes, even if the remote revocation endpoint is unavailable.
    public func signOut() async throws -> Bool {
        guard !signingIn else { throw ChatGPTError.message("请先取消当前登录。") }
        cancelRequests()
        var value = try load()
        guard let index = value.registrations.firstIndex(where: { $0.id == value.selectedID }) else { return true }
        let old = value.registrations[index]
        value.registrations[index].accessToken = nil
        value.registrations[index].refreshToken = nil
        value.registrations[index].idToken = nil
        value.registrations[index].expiresAt = nil
        value.registrations[index].scopes = []
        try save(value)
        guard let token = old.refreshToken else { return true }
        do {
            let data = try await fetch(URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/openid-configuration")!))
            struct Discovery: Decodable { let issuer: String; let revocation_endpoint: URL }
            let discovery = try JSONDecoder().decode(Discovery.self, from: data)
            guard discovery.issuer == ChatGPTProtocol.issuer, discovery.revocation_endpoint.scheme == "https",
                  discovery.revocation_endpoint.host == "auth.openai.com" else { return false }
            var request = URLRequest(url: discovery.revocation_endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = ChatGPTProtocol.form(["token": token, "token_type_hint": "refresh_token", "client_id": old.id])
            for attempt in 0..<2 {
                do { _ = try await fetch(request); return true }
                catch {
                    if attempt == 0 { try await Task.sleep(for: .seconds(1)) }
                }
            }
        } catch { return false }
        return false
    }

    private struct Tokens: Decodable, Sendable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double
        let scope: String?
        let token_type: String
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTProtocol.form(form)
        let tokens = try JSONDecoder().decode(Tokens.self, from: await fetch(request))
        guard !tokens.access_token.isEmpty, tokens.expires_in > 0, tokens.expires_in.isFinite,
              tokens.token_type.lowercased() == "bearer" else { throw ChatGPTError.message("OpenAI 返回了无效登录信息。") }
        return tokens
    }

    private func credentials() async throws -> ChatGPTRegistration {
        let value = try load()
        guard let current = value.registrations.first(where: { $0.id == value.selectedID }), current.accessToken != nil else {
            throw ChatGPTError.message("请先在设置中使用 ChatGPT 登录。")
        }
        guard current.scopes.contains(ChatGPTProtocol.permission) else {
            throw ChatGPTError.message("账号已登录，但未授权使用 ChatGPT 订阅。请重新授权并允许使用订阅额度。")
        }
        if let expiry = current.expiresAt, expiry.timeIntervalSinceNow > 90 { return current }
        guard let refresh = current.refreshToken else { throw ChatGPTError.message("登录已过期，请重新登录 ChatGPT。") }
        let epoch = generation
        let operation: (id: UUID, task: Task<ChatGPTRegistration, Error>)
        if let refreshTask { operation = refreshTask }
        else {
            operation = (UUID(), Task {
                let tokens = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": current.id,
                    "refresh_token": refresh, "resource": ChatGPTProtocol.resource])
                var updated = current
                if let idToken = tokens.id_token {
                    let keys = try await self.fetch(URLRequest(url: URL(string: ChatGPTProtocol.issuer + "/.well-known/jwks.json")!))
                    let identity = try ChatGPTIDToken.verify(idToken, keys: keys, clientID: current.id, nonce: nil)
                    guard identity.subject == current.subject else { throw ChatGPTError.message("刷新登录时账号不一致，请重新登录。") }
                    updated.idToken = idToken
                }
                updated.accessToken = tokens.access_token
                updated.refreshToken = tokens.refresh_token ?? refresh
                updated.expiresAt = Date().addingTimeInterval(tokens.expires_in)
                if let scope = tokens.scope { updated.scopes = scope.split(separator: " ").map(String.init) }
                return updated
            })
            refreshTask = operation
        }
        do {
            let updated = try await operation.task.value
            guard epoch == generation else { throw CancellationError() }
            if refreshTask?.id == operation.id {
                var value = try load()
                guard let index = value.registrations.firstIndex(where: { $0.id == updated.id }) else { throw CancellationError() }
                value.registrations[index] = updated
                try save(value)
                refreshTask = nil
            }
            // A cancelled catalog refresh must still persist rotated credentials for other callers.
            try Task.checkCancellation()
            guard updated.scopes.contains(ChatGPTProtocol.permission) else { throw ChatGPTError.message("ChatGPT 订阅权限已撤销，请重新授权。") }
            return updated
        } catch {
            if refreshTask?.id == operation.id { refreshTask = nil }
            throw error
        }
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.message("OpenAI 返回了无效响应。") }
        guard (200..<300).contains(http.statusCode) else { throw ChatGPTProtocol.serviceError(status: http.statusCode, data: data) }
        return data
    }

    private func authorizedRequest(path: String) async throws -> URLRequest {
        let registration = try await credentials()
        var request = URLRequest(url: URL(string: ChatGPTProtocol.resource + path)!)
        request.setValue("Bearer \(registration.accessToken!)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func models() async throws -> [ModelOption] {
        let epoch = generation
        let request = try await authorizedRequest(path: "/models")
        let data = try await fetch(request)
        guard epoch == generation else { throw CancellationError() }
        return try ChatGPTProtocol.models(data)
    }

    public func chat(model: String, instructions: String, history: [AIChatMessage], message: String,
                     onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        var request = try await authorizedRequest(path: "/responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try ChatGPTProtocol.requestBody(model: model, instructions: instructions, history: history, message: message)
        let session = session
        let task = Task<String, Error> {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ChatGPTError.message("OpenAI 返回了无效响应。") }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count >= 16384 { break } }
                throw ChatGPTProtocol.serviceError(status: http.statusCode, data: data)
            }
            var stream = ChatGPTEventStream()
            var line = Data()
            // AsyncBytes.lines drops empty lines, which are meaningful SSE event boundaries.
            for try await byte in bytes {
                try Task.checkCancellation()
                if byte != 10 {
                    line.append(byte)
                    guard line.count <= 1_048_576 else { throw ChatGPTError.message("OpenAI 流式响应过大。") }
                    continue
                }
                if line.last == 13 { line.removeLast() }
                guard let decoded = String(data: line, encoding: .utf8) else { throw ChatGPTError.message("OpenAI 流式响应编码无效。") }
                if let text = try stream.consume(decoded) { onPartial?(text) }
                line.removeAll(keepingCapacity: true)
                if stream.completed { break }
            }
            if !line.isEmpty, let decoded = String(data: line, encoding: .utf8) { _ = try stream.consume(decoded) }
            return try stream.finish()
        }
        let id = UUID()
        chats[id] = task
        defer { chats[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
