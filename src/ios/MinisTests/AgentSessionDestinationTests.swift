import XCTest
@testable import Minis

final class AgentSessionDestinationTests: XCTestCase {
    func testDraftRouteUsesDraftChannelInsteadOfRealSessionId() {
        let routeId = "__new__draft-123"

        let destination = AgentSessionDestination(routeId: routeId)

        XCTAssertNil(destination.sessionId)
        XCTAssertEqual(destination.draftId, routeId)
    }

    func testPersistedRouteUsesRealSessionChannel() {
        let destination = AgentSessionDestination(routeId: "session-123")

        XCTAssertEqual(destination.sessionId, "session-123")
        XCTAssertNil(destination.draftId)
    }
}
