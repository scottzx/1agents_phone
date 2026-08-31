import Foundation

/// A portable terminal colour. The AppKit renderer decides how each value maps
/// to an actual NSColor, leaving this core usable by tests and non-UI clients.
public enum TerminalColor: Equatable, Sendable {
    case `default`
    case ansi(Int)
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalTextStyle: Equatable, Sendable {
    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false

    public init() {}
}

/// A visible terminal cell. A width-two glyph owns its first cell; the second
/// cell has `isContinuation` set and must not be rendered as a separate glyph.
public struct TerminalCell: Equatable, Sendable {
    public var text: String
    public var style: TerminalTextStyle
    public var isContinuation: Bool

    public init(text: String = " ", style: TerminalTextStyle = TerminalTextStyle(), isContinuation: Bool = false) {
        self.text = text
        self.style = style
        self.isContinuation = isContinuation
    }
}

public struct TerminalScreenSnapshot: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let lines: [[TerminalCell]]
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let title: String?
    public let isAlternateScreen: Bool

    public init(columns: Int, rows: Int, lines: [[TerminalCell]], cursorColumn: Int, cursorRow: Int, cursorVisible: Bool, title: String? = nil, isAlternateScreen: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.lines = lines
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.title = title
        self.isAlternateScreen = isAlternateScreen
    }
}

/// Foundation-only VT-style terminal screen. It intentionally implements the
/// small, high-value subset emitted by login shells and command line programs:
/// UTF-8 text, SGR, CR/LF/backspace, cursor movement, and erase operations.
/// It is not a replacement for a full xterm emulator; the backend and renderer
/// can evolve independently without changing this screen contract.
public final class TerminalScreen {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorColumn = 0
    public private(set) var cursorRow = 0
    public private(set) var cursorVisible = true
    public private(set) var title: String?
    public private(set) var isAlternateScreen = false

    private let scrollbackLimit: Int
    private var grid: [[TerminalCell]]
    private var scrollback: [[TerminalCell]] = []
    private var style = TerminalTextStyle()
    private var savedCursor: (column: Int, row: Int)?
    private var primaryBuffer: SavedBuffer?
    private var parserState: ParserState = .ground
    private var utf8: UTF8Accumulator = .init()

    public init(columns: Int = 100, rows: Int = 30, scrollbackLimit: Int = 2_000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = max(0, scrollbackLimit)
        self.grid = Array(repeating: Array(repeating: TerminalCell(), count: max(1, columns)), count: max(1, rows))
    }

    public func feed(_ data: Data) {
        for byte in data {
            consume(byte)
        }
    }

    public func reset() {
        grid = Array(repeating: blankLine(), count: rows)
        scrollback.removeAll(keepingCapacity: true)
        cursorColumn = 0
        cursorRow = 0
        cursorVisible = true
        style = TerminalTextStyle()
        savedCursor = nil
        primaryBuffer = nil
        isAlternateScreen = false
        title = nil
        parserState = .ground
        utf8 = .init()
    }

    public func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }

        func resized(_ line: [TerminalCell]) -> [TerminalCell] {
            if line.count == targetColumns { return line }
            if line.count > targetColumns { return Array(line.prefix(targetColumns)) }
            return line + Array(repeating: TerminalCell(), count: targetColumns - line.count)
        }

        grid = grid.map(resized)
        scrollback = scrollback.map(resized)
        if grid.count > targetRows {
            scrollback.append(contentsOf: grid.prefix(grid.count - targetRows))
            grid.removeFirst(grid.count - targetRows)
        } else if grid.count < targetRows {
            grid.append(contentsOf: Array(repeating: Array(repeating: TerminalCell(), count: targetColumns), count: targetRows - grid.count))
        }
        trimScrollback()
        columns = targetColumns
        rows = targetRows
        cursorColumn = min(cursorColumn, columns - 1)
        cursorRow = min(cursorRow, rows - 1)
        if var primaryBuffer {
            primaryBuffer.grid = primaryBuffer.grid.map(resized)
            primaryBuffer.scrollback = primaryBuffer.scrollback.map(resized)
            if primaryBuffer.grid.count > targetRows {
                primaryBuffer.scrollback.append(contentsOf: primaryBuffer.grid.prefix(primaryBuffer.grid.count - targetRows))
                primaryBuffer.grid.removeFirst(primaryBuffer.grid.count - targetRows)
            } else if primaryBuffer.grid.count < targetRows {
                primaryBuffer.grid.append(contentsOf: Array(repeating: Array(repeating: TerminalCell(), count: targetColumns), count: targetRows - primaryBuffer.grid.count))
            }
            if primaryBuffer.scrollback.count > scrollbackLimit {
                primaryBuffer.scrollback.removeFirst(primaryBuffer.scrollback.count - scrollbackLimit)
            }
            primaryBuffer.cursorColumn = min(primaryBuffer.cursorColumn, targetColumns - 1)
            primaryBuffer.cursorRow = min(primaryBuffer.cursorRow, targetRows - 1)
            self.primaryBuffer = primaryBuffer
        }
    }

    public func snapshot() -> TerminalScreenSnapshot {
        TerminalScreenSnapshot(
            columns: columns,
            rows: rows,
            lines: scrollback + grid,
            cursorColumn: cursorColumn,
            cursorRow: scrollback.count + cursorRow,
            cursorVisible: cursorVisible,
            title: title,
            isAlternateScreen: isAlternateScreen
        )
    }

    private struct SavedBuffer {
        var grid: [[TerminalCell]]
        var scrollback: [[TerminalCell]]
        var cursorColumn: Int
        var cursorRow: Int
        var savedCursor: (column: Int, row: Int)?
        var style: TerminalTextStyle
    }

    private enum ParserState {
        case ground
        case escape
        case csi(String)
        case osc([UInt8])
        case oscEscape([UInt8])
    }

    private func consume(_ byte: UInt8) {
        switch parserState {
        case .ground:
            switch byte {
            case 0x1B:
                flushMalformedUTF8()
                parserState = .escape
            case 0x08: backspace()
            case 0x09: tab()
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x0D: carriageReturn()
            case 0x00...0x1F, 0x7F:
                break
            default:
                appendUTF8(byte)
            }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): parserState = .csi("")
            case UInt8(ascii: "]"): parserState = .osc([])
            case UInt8(ascii: "7"): saveCursor(); parserState = .ground
            case UInt8(ascii: "8"): restoreCursor(); parserState = .ground
            case UInt8(ascii: "D"): lineFeed(); parserState = .ground
            case UInt8(ascii: "M"): reverseIndex(); parserState = .ground
            case UInt8(ascii: "c"): reset(); parserState = .ground
            default: parserState = .ground
            }
        case .csi(let parameters):
            if (0x40...0x7E).contains(byte) {
                handleCSI(parameters, final: Character(UnicodeScalar(byte)))
                parserState = .ground
            } else if (0x20...0x3F).contains(byte) {
                parserState = .csi(parameters + String(UnicodeScalar(byte)))
            } else {
                parserState = .ground
            }
        case .osc(var bytes):
            if byte == 0x07 {
                handleOSC(bytes)
                parserState = .ground
            } else if byte == 0x1B {
                parserState = .oscEscape(bytes)
            } else if bytes.count < 8_192 {
                bytes.append(byte)
                parserState = .osc(bytes)
            }
        case .oscEscape(var bytes):
            if byte == UInt8(ascii: "\\") {
                handleOSC(bytes)
                parserState = .ground
            } else {
                if bytes.count < 8_192 { bytes.append(0x1B); bytes.append(byte) }
                parserState = .osc(bytes)
            }
        }
    }

    private func appendUTF8(_ byte: UInt8) {
        switch utf8.append(byte) {
        case .character(let character): write(character)
        case .replacement: write("�")
        case .waiting: break
        }
    }

    private func flushMalformedUTF8() {
        if utf8.hasPending { write("�") }
        utf8 = .init()
    }

    private func write(_ character: Character) {
        let width = characterWidth(character)
        if width == 0 {
            appendCombining(character)
            return
        }
        if cursorColumn >= columns {
            carriageReturn()
            lineFeed()
        }
        if width == 2 && cursorColumn == columns - 1 {
            carriageReturn()
            lineFeed()
        }
        clearWideCell(atColumn: cursorColumn, row: cursorRow)
        grid[cursorRow][cursorColumn] = TerminalCell(text: String(character), style: style)
        if width == 2, cursorColumn + 1 < columns {
            grid[cursorRow][cursorColumn + 1] = TerminalCell(text: "", style: style, isContinuation: true)
        }
        cursorColumn += width
    }

    private func appendCombining(_ character: Character) {
        guard cursorColumn > 0 else { return }
        let index = cursorColumn - 1
        if grid[cursorRow][index].isContinuation, index > 0 {
            grid[cursorRow][index - 1].text.append(contentsOf: String(character))
        } else {
            grid[cursorRow][index].text.append(contentsOf: String(character))
        }
    }

    private func carriageReturn() { cursorColumn = 0 }

    private func lineFeed() {
        if cursorRow == rows - 1 {
            scrollUp()
        } else {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == 0 {
            grid.insert(blankLine(), at: 0)
            _ = grid.popLast()
        } else {
            cursorRow -= 1
        }
    }

    private func backspace() { cursorColumn = max(0, cursorColumn - 1) }

    private func tab() {
        let next = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        cursorColumn = next
    }

    private func scrollUp() {
        let removed = grid.removeFirst()
        if !isAlternateScreen {
            scrollback.append(removed)
            trimScrollback()
        }
        grid.append(blankLine())
    }

    private func trimScrollback() {
        guard scrollback.count > scrollbackLimit else { return }
        scrollback.removeFirst(scrollback.count - scrollbackLimit)
    }

    private func blankLine() -> [TerminalCell] {
        Array(repeating: TerminalCell(), count: columns)
    }

    private func clearWideCell(atColumn column: Int, row: Int) {
        guard grid[row].indices.contains(column) else { return }
        if grid[row][column].isContinuation, column > 0 {
            grid[row][column - 1] = TerminalCell()
        }
        if column + 1 < columns, grid[row][column + 1].isContinuation {
            grid[row][column + 1] = TerminalCell()
        }
    }

    private func handleCSI(_ raw: String, final: Character) {
        let privateMode = raw.hasPrefix("?")
        let params = parseParameters(privateMode ? String(raw.dropFirst()) : raw)
        let amount = max(1, params.first ?? 1)
        switch final {
        case "A": cursorRow = max(0, cursorRow - amount)
        case "B": cursorRow = min(rows - 1, cursorRow + amount)
        case "C": cursorColumn = min(columns - 1, cursorColumn + amount)
        case "D": cursorColumn = max(0, cursorColumn - amount)
        case "E": cursorRow = min(rows - 1, cursorRow + amount); cursorColumn = 0
        case "F": cursorRow = max(0, cursorRow - amount); cursorColumn = 0
        case "G": cursorColumn = min(columns - 1, max(0, amount - 1))
        case "H", "f":
            cursorRow = min(rows - 1, max(0, (params.first ?? 1) - 1))
            cursorColumn = min(columns - 1, max(0, (params.dropFirst().first ?? 1) - 1))
        case "J": eraseDisplay(params.first ?? 0)
        case "K": eraseLine(params.first ?? 0)
        case "m": applySGR(params)
        case "s": saveCursor()
        case "u": restoreCursor()
        case "h" where privateMode && params.contains(25): cursorVisible = true
        case "l" where privateMode && params.contains(25): cursorVisible = false
        case "h" where privateMode && (params.contains(47) || params.contains(1047) || params.contains(1049)):
            enterAlternateScreen(saveCursor: params.contains(1049))
        case "l" where privateMode && (params.contains(47) || params.contains(1047) || params.contains(1049)):
            leaveAlternateScreen(restoreCursor: params.contains(1049))
        case "h" where privateMode && params.contains(1048): saveCursor()
        case "l" where privateMode && params.contains(1048): restoreCursor()
        default: break
        }
    }

    private func enterAlternateScreen(saveCursor shouldSaveCursor: Bool) {
        guard !isAlternateScreen else { return }
        primaryBuffer = SavedBuffer(
            grid: grid,
            scrollback: scrollback,
            cursorColumn: cursorColumn,
            cursorRow: cursorRow,
            savedCursor: savedCursor,
            style: style
        )
        if shouldSaveCursor { savedCursor = (cursorColumn, cursorRow) }
        grid = Array(repeating: blankLine(), count: rows)
        scrollback = []
        cursorColumn = 0
        cursorRow = 0
        isAlternateScreen = true
    }

    private func leaveAlternateScreen(restoreCursor shouldRestoreCursor: Bool) {
        guard isAlternateScreen, let primaryBuffer else { return }
        grid = primaryBuffer.grid
        scrollback = primaryBuffer.scrollback
        cursorColumn = primaryBuffer.cursorColumn
        cursorRow = primaryBuffer.cursorRow
        savedCursor = primaryBuffer.savedCursor
        style = primaryBuffer.style
        self.primaryBuffer = nil
        isAlternateScreen = false
        if shouldRestoreCursor { restoreCursor() }
    }

    private func handleOSC(_ bytes: [UInt8]) {
        guard let value = String(bytes: bytes, encoding: .utf8),
              let separator = value.firstIndex(of: ";") else { return }
        let command = value[..<separator]
        guard command == "0" || command == "2" else { return }
        let candidate = String(value[value.index(after: separator)...]).trimmingCharacters(in: .controlCharacters)
        title = candidate.isEmpty ? nil : String(candidate.prefix(512))
    }

    private func parseParameters(_ raw: String) -> [Int] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows { grid[row] = blankLine() }
            }
        case 1:
            eraseLine(1)
            if cursorRow > 0 {
                for row in 0..<cursorRow { grid[row] = blankLine() }
            }
        case 2:
            grid = Array(repeating: blankLine(), count: rows)
        case 3:
            grid = Array(repeating: blankLine(), count: rows)
            scrollback.removeAll(keepingCapacity: true)
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns { grid[cursorRow][column] = TerminalCell() }
        case 1:
            for column in 0...cursorColumn { grid[cursorRow][column] = TerminalCell() }
        case 2:
            grid[cursorRow] = blankLine()
        default: break
        }
    }

    private func applySGR(_ params: [Int]) {
        let values = params.isEmpty ? [0] : params
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0: style = TerminalTextStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .ansi(values[index] - 30)
            case 90...97: style.foreground = .ansi(values[index] - 90 + 8)
            case 39: style.foreground = .default
            case 40...47: style.background = .ansi(values[index] - 40)
            case 100...107: style.background = .ansi(values[index] - 100 + 8)
            case 49: style.background = .default
            case 38, 48:
                let foreground = values[index] == 38
                if index + 2 < values.count, values[index + 1] == 5 {
                    let color = TerminalColor.indexed(max(0, min(255, values[index + 2])))
                    if foreground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    let color = TerminalColor.rgb(UInt8(clamping: values[index + 2]), UInt8(clamping: values[index + 3]), UInt8(clamping: values[index + 4]))
                    if foreground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private func saveCursor() { savedCursor = (cursorColumn, cursorRow) }

    private func restoreCursor() {
        guard let savedCursor else { return }
        cursorColumn = min(columns - 1, savedCursor.column)
        cursorRow = min(rows - 1, savedCursor.row)
    }

    private func characterWidth(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        if scalars.allSatisfy({ isCombining($0.value) }) { return 0 }
        return scalars.contains(where: { isWide($0.value) }) ? 2 : 1
    }

    private func isCombining(_ value: UInt32) -> Bool {
        (0x0300...0x036F).contains(value) || (0x1AB0...0x1AFF).contains(value) || (0x1DC0...0x1DFF).contains(value) || (0x20D0...0x20FF).contains(value) || (0xFE20...0xFE2F).contains(value)
    }

    private func isWide(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value) || (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value) || (0xFE10...0xFE6F).contains(value) || (0xFF01...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value) || (0x1F300...0x1FAFF).contains(value) || (0x20000...0x3FFFD).contains(value)
    }
}

private struct UTF8Accumulator {
    enum Result {
        case waiting
        case character(Character)
        case replacement
    }

    private var bytes: [UInt8] = []
    private var expectedCount = 0
    var hasPending: Bool { !bytes.isEmpty }

    mutating func append(_ byte: UInt8) -> Result {
        if bytes.isEmpty {
            if byte < 0x80 { return .character(Character(UnicodeScalar(byte))) }
            expectedCount = expectedLength(for: byte)
            guard expectedCount > 0 else { return .replacement }
            bytes = [byte]
            return .waiting
        }
        guard (byte & 0xC0) == 0x80 else {
            bytes.removeAll(keepingCapacity: true)
            expectedCount = 0
            return .replacement
        }
        bytes.append(byte)
        guard bytes.count == expectedCount else { return .waiting }
        defer { bytes.removeAll(keepingCapacity: true); expectedCount = 0 }
        guard let text = String(bytes: bytes, encoding: .utf8), let character = text.first else { return .replacement }
        return .character(character)
    }

    private func expectedLength(for byte: UInt8) -> Int {
        switch byte {
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: 0
        }
    }
}
