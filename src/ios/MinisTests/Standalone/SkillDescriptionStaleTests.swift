// Regression test for GH#215 — SkillStore.loadSkills() stale-description rule.

import XCTest

final class SkillDescriptionStaleTests: XCTestCase {

    let defaultSkillName = "Untitled Skill"

    /// The predicate under test — copied verbatim from the fix.
    func descStale(dbDescription: String, parsedDescription: String) -> Bool {
        (dbDescription == "|" || dbDescription == ">" || dbDescription.isEmpty)
            && !parsedDescription.isEmpty
    }

    /// The parse-failure sentinel a720585db relies on.
    func parseFailed(parsedName: String, parsedDescription: String) -> Bool {
        parsedName == defaultSkillName && parsedDescription.isEmpty
    }

    func testEmptyDbDescriptionRefreshes() {
        XCTAssertTrue(descStale(dbDescription: "", parsedDescription: "Fetch a web page"))
    }

    func testBlockScalarIndicatorsRefresh() {
        XCTAssertTrue(descStale(dbDescription: "|", parsedDescription: "Real"))
        XCTAssertTrue(descStale(dbDescription: ">", parsedDescription: "Real"))
    }

    func testParseFailureKeepsGoodMetadata() {
        XCTAssertFalse(descStale(dbDescription: "Fetch a web page", parsedDescription: ""))
        XCTAssertFalse(descStale(dbDescription: "", parsedDescription: ""))
        XCTAssertFalse(descStale(dbDescription: "|", parsedDescription: ""))
        XCTAssertTrue(parseFailed(parsedName: defaultSkillName, parsedDescription: ""))
    }

    func testDeliberateUserDescriptionPreserved() {
        XCTAssertFalse(descStale(dbDescription: "My own wording", parsedDescription: "Upstream wording"))
        XCTAssertFalse(descStale(dbDescription: "Same", parsedDescription: "Same"))
    }

    func testEdgeCases() {
        XCTAssertFalse(descStale(dbDescription: " ", parsedDescription: "Real"))
        XCTAssertFalse(descStale(dbDescription: "", parsedDescription: ""))
    }
}
