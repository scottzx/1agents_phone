import XCTest
@testable import MinisDesktopCore

final class TerminalScreenTests: XCTestCase {
    func testSGRStylesCellsAndResetRestoresDefaults() {
        let screen = TerminalScreen(columns: 12, rows: 2)
        screen.feed(Data("\u{1B}[31;1mA\u{1B}[0mB".utf8))

        let line = screen.snapshot().lines[0]
        XCTAssertEqual(line[0].text, "A")
        XCTAssertEqual(line[0].style.foreground, .ansi(1))
        XCTAssertTrue(line[0].style.bold)
        XCTAssertEqual(line[1].text, "B")
        XCTAssertEqual(line[1].style.foreground, .default)
        XCTAssertFalse(line[1].style.bold)
    }

    func testCRLFBackspaceAndEraseLineOperateOnScreen() {
        let screen = TerminalScreen(columns: 8, rows: 3)
        screen.feed(Data("hello\rH\nworld\u{08}!\u{1B}[2K".utf8))

        let snapshot = screen.snapshot()
        XCTAssertEqual(String(snapshot.lines[0].prefix(5).map(\.text).joined()), "Hello")
        XCTAssertEqual(snapshot.cursorRow, 1)
        XCTAssertTrue(snapshot.lines[1].allSatisfy { $0.text == " " })
    }

    func testCursorMovementAndEraseDisplay() {
        let screen = TerminalScreen(columns: 8, rows: 3)
        screen.feed(Data("abc\u{1B}[2;4HZ\u{1B}[1;2H\u{1B}[0J".utf8))

        let snapshot = screen.snapshot()
        XCTAssertEqual(snapshot.lines[0][0].text, "a")
        XCTAssertTrue(snapshot.lines[0].dropFirst().allSatisfy { $0.text == " " })
        XCTAssertTrue(snapshot.lines[1].allSatisfy { $0.text == " " })
    }

    func testUnicodeWideGlyphConsumesTwoCellsAndUTF8MayArriveInPieces() {
        let screen = TerminalScreen(columns: 8, rows: 2)
        let bytes = Array("A终B".utf8)
        screen.feed(Data(bytes.prefix(2)))
        screen.feed(Data(bytes.dropFirst(2)))

        let line = screen.snapshot().lines[0]
        XCTAssertEqual(line[0].text, "A")
        XCTAssertEqual(line[1].text, "终")
        XCTAssertTrue(line[2].isContinuation)
        XCTAssertEqual(line[3].text, "B")
    }

    func testScrollbackRetainsPriorLinesAndCursorVisibilityMode() {
        let screen = TerminalScreen(columns: 5, rows: 2, scrollbackLimit: 2)
        screen.feed(Data("one\r\ntwo\r\nthree\r\n\u{1B}[?25l".utf8))

        let snapshot = screen.snapshot()
        XCTAssertFalse(snapshot.cursorVisible)
        XCTAssertTrue(snapshot.lines.contains { String($0.map(\.text).joined()).contains("one") })
        XCTAssertTrue(snapshot.lines.contains { String($0.map(\.text).joined()).contains("two") })
        XCTAssertTrue(snapshot.lines.contains { String($0.map(\.text).joined()).contains("three") })
    }

    func testAlternateScreenDoesNotPollutePrimaryScrollbackAndRestoresCursor() {
        let screen = TerminalScreen(columns: 8, rows: 2, scrollbackLimit: 10)
        screen.feed(Data("primary\r\nline\u{1B}[1;4H".utf8))

        screen.feed(Data("\u{1B}[?1049hfull\r\nscreen\r\nmore".utf8))
        let alternate = screen.snapshot()
        XCTAssertTrue(alternate.isAlternateScreen)
        XCTAssertFalse(alternate.lines.contains { String($0.map(\.text).joined()).contains("primary") })

        screen.feed(Data("\u{1B}[?1049l".utf8))
        let restored = screen.snapshot()
        XCTAssertFalse(restored.isAlternateScreen)
        XCTAssertTrue(restored.lines.contains { String($0.map(\.text).joined()).contains("primary") })
        XCTAssertEqual(restored.cursorColumn, 3)
        XCTAssertEqual(restored.cursorRow, 0)
    }

    func testOSCTitleSupportsBellAndStringTerminator() {
        let screen = TerminalScreen(columns: 8, rows: 2)
        screen.feed(Data("\u{1B}]0;Project shell\u{7}".utf8))
        XCTAssertEqual(screen.snapshot().title, "Project shell")
        screen.feed(Data("\u{1B}]2;Agent run\u{1B}\\".utf8))
        XCTAssertEqual(screen.snapshot().title, "Agent run")
    }
}
