import Foundation
import Security

private func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
    if !condition() { throw ChatGPTError.message("TEST FAILED: \(label)") }
}

private func rejects(_ label: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw ChatGPTError.message("TEST FAILED: accepted \(label)")
}

private final class MemoryChatGPTStore: ChatGPTVaultStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ vault: ChatGPTVault) throws { data = try JSONEncoder().encode(vault) }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ data: Data) throws { lock.lock(); defer { lock.unlock() }; self.data = data }
}

private final class MockHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data = Data()
    private var refreshes = 0
    func reset() { lock.lock(); defer { lock.unlock() }; refreshes = 0; body = Data() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return refreshes }
    func lastBody() -> Data { lock.lock(); defer { lock.unlock() }; return body }
    func response(_ request: URLRequest) -> (Int, Data, String) {
        lock.lock(); defer { lock.unlock() }
        switch request.url!.path {
        case "/api/accounts/oauth/token":
            refreshes += 1
            return (200, Data(#"{"access_token":"fixture-access","refresh_token":"fixture-rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8), "application/json")
        case "/v1/models":
            return (200, Data(#"{"models":[{"slug":"fixture-model","display_name":"Fixture","visibility":"list"},{"slug":"hidden","visibility":"hide"}]}"#.utf8), "application/json")
        case "/v1/responses":
            if let requestBody = request.httpBody { body = requestBody }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            return (200, Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8), "text/event-stream")
        case "/.well-known/openid-configuration":
            return (200, Data(#"{"issuer":"https://auth.openai.com","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}"#.utf8), "application/json")
        case "/api/accounts/oauth/revoke": return (200, Data(), "application/json")
        default: return (404, Data(), "application/json")
        }
    }
}

private final class MockChatGPTHTTP: URLProtocol, @unchecked Sendable {
    static let state = MockHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data, contentType) = Self.state.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ChatGPTTests {
    static func run() async throws {
        try authContract()
        try jwtValidation()
        try streamFailures()
        try await callbackLifecycle()
        try await serviceLifecycle()
        print("CHATGPT: OAuth, JWT signatures, callbacks, refresh, accounts, SSE and request contract passed")
    }

    private static func authContract() throws {
        let url = ChatGPTProtocol.authorizationURL(hostID: "fixture-host", redirect: "http://127.0.0.1:1234/auth/callback",
            state: "fixture-state", nonce: "fixture-nonce", challenge: "challenge", registration: nil)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        try check(items["client_id"] == "dynamic_agent_client", "dynamic registration")
        try check(items["nonce"] == "fixture-nonce" && items["resource"] == ChatGPTProtocol.resource, "OIDC and resource")
        try check(items["scope"]!.contains("chatgpt.tokens.use.direct"), "subscription consent")
        try rejects("wrong state") { _ = try ChatGPTProtocol.clientID(callback: ["state": "wrong", "client_id": "oaiapp_fixture"], expectedState: "expected", existingID: nil) }
        try rejects("bootstrap client ID") { _ = try ChatGPTProtocol.clientID(callback: ["state": "s", "client_id": "dynamic_agent_client"], expectedState: "s", existingID: nil) }
        try rejects("changed registration") { _ = try ChatGPTProtocol.clientID(callback: ["state": "s", "client_id": "other"], expectedState: "s", existingID: "saved") }
        let encoded = String(data: ChatGPTProtocol.form(["code": "a+b&=c"]), encoding: .utf8)!
        try check(encoded == "code=a%2Bb%26%3Dc", "form encoding preserves literal separators")
        let body = try ChatGPTProtocol.requestBody(model: "fixture", instructions: "Summarize", history: [AIChatMessage(role: .system, content: "context")], message: "hello")
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        try check(object["temperature"] == nil && object["store"] as? Bool == false && object["stream"] as? Bool == true, "subscription-only fields")
        try check((object["input"] as! [[String: String]])[0]["role"] == "developer", "system history remapped")
        var oldConfig = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AIConfig(authMode: .apiKey))) as! [String: Any]
        oldConfig.removeValue(forKey: "chatGPTModel")
        let restored = try JSONDecoder().decode(AIConfig.self, from: JSONSerialization.data(withJSONObject: oldConfig))
        try check(restored.authMode == .apiKey && restored.chatGPTModel == nil, "existing config remains readable")
    }

    private static func jwtValidation() throws {
        let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicData = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        let bytes = [UInt8](publicData)
        var offset = 0
        func length() -> Int {
            let first = Int(bytes[offset]); offset += 1
            if first < 128 { return first }
            var value = 0
            for _ in 0..<(first & 127) { value = value * 256 + Int(bytes[offset]); offset += 1 }
            return value
        }
        offset += 1; _ = length()
        offset += 1; let nLength = length(); let n = Data(bytes[offset..<(offset + nLength)]); offset += nLength
        offset += 1; let eLength = length(); let e = Data(bytes[offset..<(offset + eLength)])
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "fixture", "kty": "RSA", "alg": "RS256", "n": OAuthSubscriptionManager.base64URLEncode(n), "e": OAuthSubscriptionManager.base64URLEncode(e)]]])
        let now = Date()
        func token(_ replacements: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
            var claims: [String: Any] = ["iss": ChatGPTProtocol.issuer, "sub": "fixture-user", "aud": "oaiapp_fixture", "nonce": "nonce", "exp": now.timeIntervalSince1970 + 300]
            claims.merge(replacements) { _, new in new }
            let header = OAuthSubscriptionManager.base64URLEncode(try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "fixture"]))
            let body = OAuthSubscriptionManager.base64URLEncode(try JSONSerialization.data(withJSONObject: claims))
            let message = "\(header).\(body)"
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)! as Data
            return message + "." + OAuthSubscriptionManager.base64URLEncode(signature)
        }
        let good = try token()
        let identity = try ChatGPTIDToken.verify(good, keys: keys, clientID: "oaiapp_fixture", nonce: "nonce", now: now)
        try check(identity.subject == "fixture-user", "valid RSA identity")
        for (label, claims) in [("issuer", ["iss": "https://example.org"]), ("audience", ["aud": "other"]), ("nonce", ["nonce": "other"]), ("expiry", ["exp": now.timeIntervalSince1970 - 60])] as [(String, [String: Any])] {
            try rejects(label) { _ = try ChatGPTIDToken.verify(token(claims), keys: keys, clientID: "oaiapp_fixture", nonce: "nonce", now: now) }
        }
        try rejects("algorithm substitution") { _ = try ChatGPTIDToken.verify(token(algorithm: "none"), keys: keys, clientID: "oaiapp_fixture", nonce: "nonce", now: now) }
        var components = good.split(separator: ".").map(String.init)
        components[1] = OAuthSubscriptionManager.base64URLEncode(Data(#"{"sub":"tampered"}"#.utf8))
        try rejects("signature tampering") { _ = try ChatGPTIDToken.verify(components.joined(separator: "."), keys: keys, clientID: "oaiapp_fixture", nonce: "nonce", now: now) }
    }

    private static func streamFailures() throws {
        var incomplete = ChatGPTEventStream()
        _ = try incomplete.consume(#"data: {"type":"response.output_text.delta","delta":"half"}"#)
        _ = try incomplete.consume("")
        try rejects("truncated SSE") { _ = try incomplete.finish() }
        var failed = ChatGPTEventStream()
        _ = try failed.consume(#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#)
        try rejects("mid-stream quota failure") { _ = try failed.consume("") }
        var multi = ChatGPTEventStream()
        _ = try multi.consume("data: {\"type\":\"response.output_text.delta\",")
        _ = try multi.consume("data: \"delta\":\"OK\"}")
        _ = try multi.consume("")
        _ = try multi.consume(#"data: {"type":"response.completed"}"#)
        let result = try multi.finish()
        try check(result == "OK", "multi-line SSE and EOF dispatch")
    }

    private static func callbackLifecycle() async throws {
        let listener = try ChatGPTCallbackServer(state: "fixture")
        let port = try await listener.start(timeout: 5)
        defer { listener.cancel() }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let bad = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=fixture&state=wrong")!
        let (_, badResponse) = try await session.data(from: bad)
        try check((badResponse as? HTTPURLResponse)?.statusCode == 400, "invalid callback does not consume login")
        let good = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=fixture&state=fixture&client_id=oaiapp_fixture")!
        _ = try await session.data(from: good)
        let callback = try await listener.wait()
        try check(callback["code"] == "fixture", "callback before wait is retained")
        let cancelled = try ChatGPTCallbackServer(state: "fixture")
        _ = try await cancelled.start(timeout: 5)
        cancelled.cancel()
        do { _ = try await cancelled.wait(); throw ChatGPTError.message("TEST FAILED: cancelled callback accepted") }
        catch is CancellationError {}
    }

    private static func serviceLifecycle() async throws {
        MockChatGPTHTTP.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockChatGPTHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let original = ChatGPTRegistration(id: "oaiapp_fixture", subject: "fixture-user", email: nil,
            accessToken: "fixture-expired", refreshToken: "fixture-refresh", idToken: nil,
            expiresAt: Date(timeIntervalSince1970: 0), scopes: [ChatGPTProtocol.permission])
        var vault = ChatGPTVault()
        vault.selectedID = original.id
        vault.registrations = [original]
        let store = try MemoryChatGPTStore(vault)
        let service = ChatGPTService(store: store, session: session)
        async let first = service.models()
        async let second = service.models()
        let (a, b) = try await (first, second)
        try check(a.map(\.id) == ["fixture-model"] && b.count == 1, "account model catalog")
        try check(MockChatGPTHTTP.state.count() == 1, "concurrent refresh coalesced")
        let saved = try JSONDecoder().decode(ChatGPTVault.self, from: store.read()!)
        try check(saved.registrations[0].refreshToken == "fixture-rotated", "refresh rotation persisted")
        let result = try await service.chat(model: "fixture-model", instructions: "", history: [], message: "test", onPartial: nil)
        try check(result == "OK", "URLSession streaming end to end")
        let body = try JSONSerialization.jsonObject(with: MockChatGPTHTTP.state.lastBody()) as! [String: Any]
        try check(body["model"] as? String == "fixture-model", "inference uses chosen account model")
        let revoked = try await service.signOut()
        let account = try await service.selectedAccount()
        try check(revoked && account?.signedIn == false, "logout revokes and clears credentials")
        let signedOut = try JSONDecoder().decode(ChatGPTVault.self, from: store.read()!)
        try check(signedOut.hostID == vault.hostID && signedOut.registrations[0].id == original.id, "logout retains host and registration")
        do { _ = try await service.models(); throw ChatGPTError.message("TEST FAILED: logged-out inference accepted") }
        catch ChatGPTError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "signed-out model requests blocked") }
        var denied = vault
        denied.registrations[0].scopes = ["openid"]
        let deniedService = ChatGPTService(store: try MemoryChatGPTStore(denied), session: session)
        do { _ = try await deniedService.models(); throw ChatGPTError.message("TEST FAILED: missing consent accepted") }
        catch ChatGPTError.message(let message) { try check(!message.hasPrefix("TEST FAILED"), "identity-only login cannot use plan") }

        let cancelledStore = try MemoryChatGPTStore(vault)
        let cancelledService = ChatGPTService(store: cancelledStore, session: session)
        let cancelledRequest = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelledService.models()
        }
        do { _ = try await cancelledRequest.value; throw ChatGPTError.message("TEST FAILED: cancelled request completed") }
        catch is CancellationError {}
        let rotated = try JSONDecoder().decode(ChatGPTVault.self, from: cancelledStore.read()!)
        try check(rotated.registrations[0].refreshToken == "fixture-rotated", "cancelled waiter still persists rotation")
        let expiredError = ChatGPTProtocol.serviceError(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
        try check(expiredError.localizedDescription.contains("重新登录"), "expired refresh requires login")
    }
}
