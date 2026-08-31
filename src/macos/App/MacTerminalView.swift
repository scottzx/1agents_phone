import AppKit
import SwiftUI
import MinisDesktopCore

/// AppKit-backed terminal renderer. The screen model remains in
/// `MinisDesktopCore`; this view is only responsible for turning a screen
/// snapshot into selectable, copyable macOS text with ANSI colour attributes.
struct MacTerminalView: NSViewRepresentable {
    let output: String
    var columns: Int = 100
    var rows: Int = 30
    var onResize: ((Int, Int) -> Void)?
    var onFocus: (() -> Void)?
    var onClear: (() -> Void)?
    var onClose: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(columns: columns, rows: rows, onResize: onResize, onFocus: onFocus, onClear: onClear, onClose: onClose)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = TerminalScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black

        let textView = TerminalTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.backgroundColor = .black
        textView.textColor = .textColor
        textView.insertionPointColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 20, height: 20)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        scrollView.onViewportChange = { size in context.coordinator.viewportChanged(size) }
        context.coordinator.configureCallbacks(textView)
        context.coordinator.render(output, into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.resize(columns: columns, rows: rows)
        context.coordinator.onResize = onResize
        context.coordinator.onFocus = onFocus
        context.coordinator.onClear = onClear
        context.coordinator.onClose = onClose
        guard let textView = scrollView.documentView as? TerminalTextView else { return }
        context.coordinator.configureCallbacks(textView)
        context.coordinator.render(output, into: textView)
    }

    @MainActor
    final class Coordinator {
        private var screen: TerminalScreen
        private var renderedOutput = ""
        private var lastReportedSize: (Int, Int)?
        var onResize: ((Int, Int) -> Void)?
        var onFocus: (() -> Void)?
        var onClear: (() -> Void)?
        var onClose: (() -> Void)?

        init(
            columns: Int,
            rows: Int,
            onResize: ((Int, Int) -> Void)?,
            onFocus: (() -> Void)?,
            onClear: (() -> Void)?,
            onClose: (() -> Void)?
        ) {
            screen = TerminalScreen(columns: columns, rows: rows)
            self.onResize = onResize
            self.onFocus = onFocus
            self.onClear = onClear
            self.onClose = onClose
        }

        func configureCallbacks(_ textView: TerminalTextView) {
            textView.onFocus = { [weak self] in self?.onFocus?() }
            textView.onClear = { [weak self] in self?.onClear?() }
            textView.onClose = { [weak self] in self?.onClose?() }
        }

        func resize(columns: Int, rows: Int) {
            screen.resize(columns: columns, rows: rows)
        }

        func render(_ output: String, into textView: NSTextView) {
            guard output != renderedOutput else { return }
            if output.hasPrefix(renderedOutput) {
                let start = output.index(output.startIndex, offsetBy: renderedOutput.count)
                screen.feed(Data(output[start...].utf8))
            } else {
                // The view model bounds retained output. Once the prefix has
                // been dropped, recreate the visual state from the retained
                // stream instead of applying an invalid suffix diff.
                screen.reset()
                screen.feed(Data(output.utf8))
            }
            renderedOutput = output

            let wasAtBottom = isAtBottom(textView)
            textView.textStorage?.setAttributedString(Self.attributedText(from: screen.snapshot()))
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        }

        func viewportChanged(_ size: NSSize) {
            let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
            let cellHeight = max(1, font.ascender - font.descender + font.leading)
            let dimensions = (max(2, Int((size.width - 16) / cellWidth)), max(2, Int((size.height - 16) / cellHeight)))
            guard lastReportedSize?.0 != dimensions.0 || lastReportedSize?.1 != dimensions.1 else { return }
            lastReportedSize = dimensions
            screen.resize(columns: dimensions.0, rows: dimensions.1)
            onResize?(dimensions.0, dimensions.1)
        }

        private func isAtBottom(_ textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let visibleBottom = scrollView.contentView.bounds.maxY
            return visibleBottom >= textView.bounds.maxY - 16
        }

        private static func attributedText(from snapshot: TerminalScreenSnapshot) -> NSAttributedString {
            let rendered = NSMutableAttributedString()
            for (row, line) in snapshot.lines.enumerated() {
                for (column, cell) in line.enumerated() where !cell.isContinuation {
                    let style = cell.style
                    var foreground = color(style.foreground, isBackground: false)
                    var background = color(style.background, isBackground: true)
                    if style.inverse { swap(&foreground, &background) }
                    if snapshot.cursorVisible && row == snapshot.cursorRow && column == snapshot.cursorColumn {
                        swap(&foreground, &background)
                    }
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: style.bold ? .bold : .regular),
                        .foregroundColor: foreground,
                        .backgroundColor: background,
                    ]
                    if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if style.italic { attributes[.obliqueness] = 0.18 }
                    if style.dim { attributes[.foregroundColor] = foreground.withAlphaComponent(0.58) }
                    rendered.append(NSAttributedString(string: cell.text.isEmpty ? " " : cell.text, attributes: attributes))
                }
                if row + 1 < snapshot.lines.count { rendered.append(NSAttributedString(string: "\n")) }
            }
            return rendered
        }

        private static func color(_ value: TerminalColor, isBackground: Bool) -> NSColor {
            switch value {
            case .default:
                return isBackground ? .black : NSColor(calibratedWhite: 0.91, alpha: 1)
            case .ansi(let index):
                return ansiColor(index)
            case .indexed(let index):
                return indexedColor(index)
            case .rgb(let red, let green, let blue):
                return NSColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
            }
        }

        private static func ansiColor(_ index: Int) -> NSColor {
            let palette: [(CGFloat, CGFloat, CGFloat)] = [
                (0.05, 0.05, 0.05), (0.80, 0.18, 0.18), (0.20, 0.68, 0.28), (0.82, 0.66, 0.18),
                (0.25, 0.47, 0.90), (0.72, 0.31, 0.75), (0.18, 0.68, 0.72), (0.84, 0.84, 0.84),
                (0.38, 0.38, 0.38), (1.00, 0.35, 0.35), (0.38, 0.86, 0.42), (1.00, 0.86, 0.34),
                (0.42, 0.62, 1.00), (0.94, 0.47, 0.96), (0.36, 0.90, 0.94), (1.00, 1.00, 1.00),
            ]
            let rgb = palette[max(0, min(palette.count - 1, index))]
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }

        private static func indexedColor(_ index: Int) -> NSColor {
            if index < 16 { return ansiColor(index) }
            if index >= 232 {
                let component = CGFloat(index - 232) / 23
                return NSColor(calibratedWhite: 0.08 + component * 0.84, alpha: 1)
            }
            let value = index - 16
            let levels: [CGFloat] = [0, 0.37, 0.53, 0.68, 0.83, 1]
            let red = levels[value / 36]
            let green = levels[(value / 6) % 6]
            let blue = levels[value % 6]
            return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
        }
    }


    @MainActor
    final class TerminalScrollView: NSScrollView {
        var onViewportChange: ((NSSize) -> Void)?
        override func layout() {
            super.layout()
            onViewportChange?(contentSize)
        }
    }

    @MainActor
    final class TerminalTextView: NSTextView {
        var onFocus: (() -> Void)?
        var onClear: (() -> Void)?
        var onClose: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k":
                onClear?()
                return true
            case "w":
                onClose?()
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
    }
}
