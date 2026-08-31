import AppKit
import CryptoKit
import Foundation
import Darwin

enum OpenRouterOAuthError: LocalizedError {
    case callbackServer(String)
    case callbackTimedOut
    case callbackRejected(String)
    case invalidResponse
    case exchangeFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .callbackServer(let message): "Could not start the local OAuth callback: \(message)"
        case .callbackTimedOut: "OpenRouter sign-in timed out."
        case .callbackRejected(let message): "OpenRouter sign-in failed: \(message)"
        case .invalidResponse: "OpenRouter returned an invalid sign-in response."
        case .exchangeFailed(let status, let message): "OpenRouter key exchange failed (HTTP \(status)): \(message)"
        }
    }
}

/// macOS host for OpenRouter's PKCE flow. The provider returns a permanent API
/// key, which is handed to the Runtime and stored in its Keychain service.
@MainActor
final class OpenRouterOAuthCoordinator {
    private static let callbackPort: UInt16 = 3000
    private static let callbackURL = "http://127.0.0.1:\(callbackPort)/callback"

    func signIn() async throws -> String {
        let pkce = Self.makePKCE()
        let server = OpenRouterCallbackServer(port: Self.callbackPort)
        try server.start()
        defer { server.stop() }

        guard NSWorkspace.shared.open(Self.authorizationURL(challenge: pkce.challenge)) else {
            throw OpenRouterOAuthError.callbackRejected("The browser could not be opened.")
        }
        let code = try await server.waitForCode(timeout: 300)
        return try await exchange(code: code, verifier: pkce.verifier)
    }

    static func authorizationURL(challenge: String) -> URL {
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    static func makePKCE() -> (verifier: String, challenge: String) {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<96).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return (verifier, challenge)
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/OpenMinis/OpenMinis", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Minis App", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(KeyExchangeRequest(
            code: code,
            codeVerifier: verifier,
            codeChallengeMethod: "S256"
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterOAuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterOAuthError.exchangeFailed(http.statusCode, String(decoding: data.prefix(2_048), as: UTF8.self))
        }
        guard let key = try? JSONDecoder().decode(KeyExchangeResponse.self, from: data).key, !key.isEmpty else {
            throw OpenRouterOAuthError.invalidResponse
        }
        return key
    }

    private struct KeyExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod: String

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }

    private struct KeyExchangeResponse: Decodable { let key: String }
}

private final class OpenRouterCallbackServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.openminis.oauth.openrouter.callback")
    private var listenSocket: Int32 = -1
    private var continuation: CheckedContinuation<String, Error>?
    private var bufferedResult: Result<String, Error>?
    private var stopped = false

    init(port: UInt16) { self.port = port }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OpenRouterOAuthError.callbackServer(String(cString: strerror(errno))) }
        var reuse: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            throw OpenRouterOAuthError.callbackServer(String(cString: strerror(errno)))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0, Darwin.listen(fd, 1) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw OpenRouterOAuthError.callbackServer(message)
        }
        listenSocket = fd
        queue.async { [weak self] in self?.acceptOne() }
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: OpenRouterOAuthError.callbackTimedOut)
                    return
                }
                if let result = bufferedResult {
                    bufferedResult = nil
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(OpenRouterOAuthError.callbackTimedOut))
                }
            }
        }
    }

    func stop() {
        let fd = listenSocket
        listenSocket = -1
        stopped = true
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    private func acceptOne() {
        guard !stopped, listenSocket >= 0 else { return }
        let client = Darwin.accept(listenSocket, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.read(client, &buffer, buffer.count)
        guard count > 0,
              let request = String(bytes: buffer[..<count], encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)")
        else {
            send(client, status: "400 Bad Request", message: "Invalid callback request")
            finish(.failure(OpenRouterOAuthError.invalidResponse))
            return
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            send(client, status: "400 Bad Request", message: "Authorization failed")
            finish(.failure(OpenRouterOAuthError.callbackRejected(error)))
            return
        }
        guard components.path == "/callback",
              let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            send(client, status: "400 Bad Request", message: "Missing authorization code")
            finish(.failure(OpenRouterOAuthError.invalidResponse))
            return
        }
        send(client, status: "200 OK", message: "Authorization complete. You can return to Minis.")
        finish(.success(code))
    }

    private func finish(_ result: Result<String, Error>) {
        guard !stopped else { return }
        stopped = true
        let callback = continuation
        continuation = nil
        if let callback { callback.resume(with: result) } else { bufferedResult = result }
    }

    private func send(_ fd: Int32, status: String, message: String) {
        let body = "<html><body><h2>\(message)</h2></body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        response.withCString { pointer in _ = Darwin.write(fd, pointer, strlen(pointer)) }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
