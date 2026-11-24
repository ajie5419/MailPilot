import Foundation
import Network

/// A single-use loopback listener; every mutable field is confined to its queue.
final class ChatGPTCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mailpilot.chatgpt.callback")
    private let state: String
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var connections: [UUID: NWConnection] = [:]

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(timeout: TimeInterval = 180) async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result = self.result {
                        switch result {
                        case .failure(let error): continuation.resume(throwing: error)
                        case .success: continuation.resume(throwing: CancellationError())
                        }
                        return
                    }
                    self.startContinuation = continuation
                    self.listener.stateUpdateHandler = { [weak self] status in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = self.listener.port?.rawValue else { return }
                            self.startContinuation?.resume(returning: port)
                            self.startContinuation = nil
                        case .failed:
                            self.finish(.failure(ChatGPTError.message("无法启动本机登录回调，请重试。")))
                        default: break
                        }
                    }
                    self.listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { connection.cancel(); return }
                        self.accept(connection)
                    }
                    self.listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(ChatGPTError.message("浏览器授权已超时，请重新登录。")))
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    func wait() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else { self.callbackContinuation = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard self.result == nil else { return }
        self.result = result
        if case .failure(let error) = result { startContinuation?.resume(throwing: error) }
        startContinuation = nil
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    static func parse(_ request: String, expectedState: String, port: UInt16) -> [String: String]? {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              let url = URLComponents(string: "http://127.0.0.1" + first[1]), url.path == "/auth/callback",
              let host = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") }),
              host.dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else { return nil }
        var params: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard params[item.name] == nil, let value = item.value else { return nil }
            params[item.name] = value
        }
        guard params["state"] == expectedState, params["code"] != nil || params["error"] != nil else { return nil }
        return params
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            guard self.result == nil, error == nil else { connection.cancel(); self.connections[id] = nil; return }
            let buffer = buffer + (data ?? Data())
            guard buffer.count <= 16384 else { connection.cancel(); self.connections[id] = nil; return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel(); self.connections[id] = nil }
                else { self.receive(connection, id: id, buffer: buffer) }
                return
            }
            let callback = Self.parse(request, expectedState: self.state, port: self.listener.port?.rawValue ?? 0)
            let text = callback == nil ? "无效回调，请返回原授权页面。" : "已收到授权结果。请返回 MailPilot 查看登录验证结果。"
            let body = Data("<!doctype html><meta charset=\"utf-8\"><title>MailPilot</title><p>\(text)</p>".utf8)
            let head = "HTTP/1.1 \(callback == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel(); self.connections[id] = nil
                if let callback { self.finish(.success(callback)) }
            })
        }
    }
}
