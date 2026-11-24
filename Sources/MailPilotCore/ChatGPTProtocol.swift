import Foundation
import Security

public enum ChatGPTError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

/// The direct subscription route has a different contract from API-key chat completions.
enum ChatGPTProtocol {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let permission = "chatgpt.tokens.use.direct"

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.message("无法生成安全登录参数，请重试。")
        }
        return OAuthSubscriptionManager.base64URLEncode(Data(bytes))
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    static func authorizationURL(hostID: String, redirect: String, state: String, nonce: String,
                                 challenge: String, registration: ChatGPTRegistration?) -> URL {
        var url = URLComponents(string: issuer + "/api/accounts/authorize")!
        var params = ["client_id": registration?.id ?? "dynamic_agent_client",
                      "ext_agent_host_id": hostID, "response_type": "code", "redirect_uri": redirect,
                      "scope": scopes, "resource": resource, "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": challenge]
        if let registration {
            if let token = registration.idToken { params["id_token_hint"] = token }
            if let email = registration.email { params["login_hint"] = email }
        } else {
            params["agent_name_hint"] = "MailPilot"
        }
        url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    static func clientID(callback: [String: String], expectedState: String, existingID: String?) throws -> String {
        guard callback["state"] == expectedState else { throw ChatGPTError.message("登录校验失败，请重新登录。") }
        if callback["error"] != nil { throw ChatGPTError.message("未完成 OpenAI 授权，可以重新登录。") }
        if let existingID {
            guard callback["client_id"] == nil || callback["client_id"] == existingID else {
                throw ChatGPTError.message("登录返回的应用注册信息不一致，已中止。")
            }
            return existingID
        }
        guard let id = callback["client_id"], !id.isEmpty, id != "dynamic_agent_client" else {
            throw ChatGPTError.message("OpenAI 未返回应用注册 ID，本次登录未完成。")
        }
        return id
    }

    static func requestBody(model: String, instructions: String, history: [AIChatMessage], message: String) throws -> Data {
        guard !model.isEmpty else { throw ChatGPTError.message("请先登录并选择当前账号的模型。") }
        let input = history.map { ["role": $0.role == .system ? "developer" : $0.role.rawValue, "content": $0.content] }
            + [["role": "user", "content": message]]
        return try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instructions,
            "input": input, "stream": true, "store": false])
    }

    static func models(_ data: Data) throws -> [ModelOption] {
        struct Catalog: Decodable {
            struct Entry: Decodable { let slug: String; let display_name: String?; let visibility: String }
            let models: [Entry]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen = Set<String>()
        return catalog.models.filter { $0.visibility == "list" && seen.insert($0.slug).inserted }
            .map { ModelOption(id: $0.slug, displayName: $0.display_name ?? $0.slug) }
    }

    /// Avoid reflecting response bodies that could contain credentials or email contents.
    static func serviceError(status: Int, data: Data = Data()) -> ChatGPTError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let response = object?["response"] as? [String: Any]
        let nested = response?["error"] as? [String: Any]
        let code = (error?["code"] ?? nested?["code"] ?? object?["code"]) as? String
        if code == "invalid_grant" || object?["error"] as? String == "invalid_grant" {
            return .message("ChatGPT 登录已过期或被撤销，请重新登录。")
        }
        if code == "subscription_sharing_usage_limit_exceeded" || code == "subscription_sharing_usage_unavailable" {
            return .message("ChatGPT 订阅额度暂不可用，请在 ChatGPT 设置 → 使用量中检查 MailPilot 的权限与额度。")
        }
        switch status {
        case 401: return .message("ChatGPT 登录已失效，请重新登录。")
        case 403: return .message("OpenAI 未允许此账号或地区使用订阅接入，请检查账号权限。")
        case 429: return .message("ChatGPT 使用量受限，请稍后重试或查看使用量设置。")
        default: return .message("OpenAI 请求未完成（HTTP \(status)），请重试。")
        }
    }
}

/// Only a verified ID token may establish account identity; decoding a JWT alone is insufficient.
enum ChatGPTIDToken {
    struct Identity: Sendable { let subject: String; let email: String? }
    struct JWK: Decodable {
        let kid: String; let kty: String; let alg: String?; let use: String?
        let n: String?; let e: String?
    }
    struct KeySet: Decodable { let keys: [JWK] }

    static func decode(_ text: String) -> Data? {
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }

    static func der(tag: UInt8, bytes: Data) -> Data {
        var header = Data([tag])
        if bytes.count < 128 { header.append(UInt8(bytes.count)) }
        else {
            var count = bytes.count
            var length = [UInt8]()
            while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
            header.append(0x80 | UInt8(length.count)); header.append(contentsOf: length)
        }
        return header + bytes
    }

    static func verify(_ token: String, keys: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> Identity {
        func invalid() -> ChatGPTError { .message("OpenAI 身份签名或账号校验失败，未保存登录信息。") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let body = decode(parts[1]),
              let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw invalid() }
        let set = try JSONDecoder().decode(KeySet.self, from: keys)
        let matching = set.keys.filter { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }
        guard matching.count == 1, let n = matching[0].n.flatMap(decode), let e = matching[0].e.flatMap(decode),
              !n.isEmpty, !e.isEmpty else { throw invalid() }
        func integer(_ input: Data) -> Data {
            let unsigned = Data(input.drop(while: { $0 == 0 }))
            let positive = (unsigned.first ?? 0) & 0x80 != 0 ? Data([0]) + unsigned : unsigned
            return der(tag: 0x02, bytes: positive)
        }
        let keyData = der(tag: 0x30, bytes: integer(n) + integer(e))
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
              kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              claims["iss"] as? String == ChatGPTProtocol.issuer,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 else { throw invalid() }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID),
              (audience.count == 1 || claims["azp"] as? String == clientID),
              claims["azp"] == nil || claims["azp"] as? String == clientID,
              nonce == nil || claims["nonce"] as? String == nonce else { throw invalid() }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 30 { throw invalid() }
        return Identity(subject: sub, email: claims["email"] as? String)
    }
}

/// SSE must reach response.completed; partial text is not a successful response.
struct ChatGPTEventStream {
    private var lines: [String] = []
    private(set) var text = ""
    private(set) var completed = false

    mutating func consume(_ line: String) throws -> String? {
        if !line.isEmpty {
            if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        guard !lines.isEmpty else { return nil }
        let payload = lines.joined(separator: "\n"); lines.removeAll()
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        if type == "response.failed" || type == "error" { throw ChatGPTProtocol.serviceError(status: 400, data: data) }
        if type == "response.incomplete" { throw ChatGPTError.message("回答未完成，请重试；已生成的片段不代表完整回答。") }
        if type == "response.output_text.delta", let delta = event["delta"] as? String {
            text += delta; return text
        }
        if type == "response.refusal.delta", let delta = event["delta"] as? String {
            text += delta; return text
        }
        if type == "response.completed" {
            if let response = event["response"] as? [String: Any], let status = response["status"] as? String, status != "completed" {
                throw ChatGPTProtocol.serviceError(status: 400, data: data)
            }
            completed = true
        }
        return nil
    }

    mutating func finish() throws -> String {
        _ = try consume("")
        guard completed else { throw ChatGPTError.message("连接中断，尚未收到完整回答，请重试。") }
        guard !text.isEmpty else { throw ChatGPTError.message("OpenAI 未返回文本回答。") }
        return text
    }
}
