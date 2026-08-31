import XCTest
@testable import MinisMac

final class FileContextFormatterTests: XCTestCase {
    func testPathContextDoesNotClaimToReadOrExecuteFiles() {
        let message = FileContextFormatter.message(for: [
            URL(fileURLWithPath: "/tmp/brief.md"),
            URL(fileURLWithPath: "/tmp/data.csv"),
        ])

        XCTAssertTrue(message.contains(FileContextFormatter.safetyNotice))
        XCTAssertTrue(message.contains("- /tmp/brief.md"))
        XCTAssertTrue(message.contains("- /tmp/data.csv"))
        XCTAssertFalse(message.contains("file contents:"))
    }
}
