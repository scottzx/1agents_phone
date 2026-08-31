import Foundation
import XCTest
@testable import MinisDesktopCore
import MinisProviderDomain

final class KimiOAuthTests: XCTestCase {
    func testDeviceFlowUsesFormEncodingAndHandlesPendingSlowDown() async throws {
        let transport = KimiOAuthTestTransport(responses: [
            .json(200, [
                "device_code": "device-1", "user_code": "ABCD-EFGH",
                "verification_uri": "https://auth.kimi.com/activate",
                "expires_in": 60, "interval": 1,
            ]),
            .json(400, ["error": "authorization_pending"]),
            .json(400, ["error": "slow_down"]),
            .json(200, ["access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3600]),
        ])
        let sleeper = KimiOAuthTestSleeper()
        let credentials = InMemoryCredentialStore()
        let manager = KimiOAuthManager(credentials: credentials, transport: transport, sleeper: sleeper)

        let authorization = try await manager.requestDeviceAuthorization()
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURL.absoluteString, "https://auth.kimi.com/activate")
        let token = try await manager.completeDeviceAuthorization(authorization, account: "kimi")
        XCTAssertEqual(token.accessToken, "access-1")
        let validToken = try await manager.validAccessToken(account: "kimi")
        XCTAssertEqual(validToken, "access-1")

        let sleeps = await sleeper.values()
        XCTAssertEqual(sleeps, [1, 1, 6])
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let firstBody = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains("client_id="))
        XCTAssertFalse(firstBody.contains("scope="))
    }

    func testConcurrentExpiredTokenRefreshIsSingleFlight() async throws {
        let credentials = InMemoryCredentialStore()
        let expired = KimiOAuthToken(
            accessToken: "old-access", refreshToken: "refresh-1",
            expiresAt: Date(timeIntervalSince1970: 1), deviceID: "device"
        )
        try await credentials.save(String(decoding: JSONEncoder().encode(expired), as: UTF8.self), account: "kimi")
        let transport = KimiOAuthTestTransport(
            responses: [.json(200, ["access_token": "new-access", "refresh_token": "refresh-2", "expires_in": 3600])],
            responseDelay: .milliseconds(50)
        )
        let manager = KimiOAuthManager(credentials: credentials, transport: transport)

        async let first = manager.validAccessToken(account: "kimi", now: Date())
        async let second = manager.validAccessToken(account: "kimi", now: Date())
        let values = try await [first, second]
        XCTAssertEqual(values, ["new-access", "new-access"])
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testProviderRunnerRefreshesKimiOAuthBeforeRequest() async throws {
        let credentials = InMemoryCredentialStore()
        let expired = KimiOAuthToken(
            accessToken: "old-access", refreshToken: "refresh-1",
            expiresAt: Date(timeIntervalSince1970: 1), deviceID: "device"
        )
        try await credentials.save(String(decoding: JSONEncoder().encode(expired), as: UTF8.self), account: "kimi")
        let transport = KimiOAuthTestTransport(responses: [
            .json(200, ["access_token": "fresh-access", "refresh_token": "refresh-2", "expires_in": 3600]),
            .json(200, ["choices": [["message": ["role": "assistant", "content": "OK"]]]]),
        ])
        let runner = OpenAICompatibleProviderRunner(credentials: credentials, transport: transport)
        let configuration = ProviderConfiguration(
            id: "kimi", displayName: "Kimi", endpoint: URL(string: "https://api.kimi.com/coding/v1/chat/completions")!,
            model: ProviderModel(id: "kimi-k3"), providerType: .kimiCode, credentialType: .oauth
        )

        let text = try await runner.respond(
            messages: [RuntimeMessageRecord(sessionID: "s", role: .user, text: "hello")],
            systemPrompt: nil,
            configuration: configuration
        )
        XCTAssertEqual(text, "OK")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access")
        XCTAssertFalse(String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self).contains("fresh-access"))
    }
}

private actor KimiOAuthTestSleeper: KimiOAuthSleeping {
    private var sleeps: [TimeInterval] = []
    func sleep(seconds: TimeInterval) { sleeps.append(seconds) }
    func values() -> [TimeInterval] { sleeps }
}

private actor KimiOAuthTestTransport: ProviderHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data

        static func json(_ status: Int, _ value: Any) -> Response {
            Response(status: status, body: try! JSONSerialization.data(withJSONObject: value))
        }
    }

    private var queued: [Response]
    private var captured: [URLRequest] = []
    private let responseDelay: Duration?

    init(responses: [Response], responseDelay: Duration? = nil) {
        self.queued = responses
        self.responseDelay = responseDelay
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        if let responseDelay { try await Task.sleep(for: responseDelay) }
        guard !queued.isEmpty else { throw URLError(.badServerResponse) }
        let next = queued.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        return (next.body, response)
    }

    func requests() -> [URLRequest] { captured }
    func requestCount() -> Int { captured.count }
}
