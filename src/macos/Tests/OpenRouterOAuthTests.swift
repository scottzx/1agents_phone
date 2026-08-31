import XCTest
@testable import MinisMac

final class OpenRouterOAuthTests: XCTestCase {
    @MainActor
    func testAuthorizationURLCarriesPKCEAndLoopbackCallback() throws {
        let pkce = OpenRouterOAuthCoordinator.makePKCE()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.verifier.contains("="))
        XCTAssertFalse(pkce.challenge.contains("="))

        let url = OpenRouterOAuthCoordinator.authorizationURL(challenge: pkce.challenge)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "openrouter.ai")
        XCTAssertEqual(query["callback_url"], "http://127.0.0.1:3000/callback")
        XCTAssertEqual(query["code_challenge"], pkce.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
    }

    @MainActor
    func testPKCEGenerationIsUnique() {
        XCTAssertNotEqual(OpenRouterOAuthCoordinator.makePKCE().verifier, OpenRouterOAuthCoordinator.makePKCE().verifier)
    }
}
