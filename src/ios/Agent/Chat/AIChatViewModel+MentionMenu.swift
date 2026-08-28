import Foundation

// MARK: - File Mention (`@`) Menu

/// Diagnostic logger for the `@` file-mention picker. Category is fixed so
/// users can grep `[MentionPicker]` in shared logs to reconstruct a stuck-
/// picker incident. See T-ios-mention-list-stuck-diag.
private let mentionPickerLogger = AppLogger(category: "MentionPicker")

// MARK: - Group Mentions

/// One row of the `@` menu inside a group: a member, or the whole room.
///
/// Separate from FileMentionEntry rather than a case on it because the two
/// mean opposite things — a file mention pastes a path INTO the message, a
/// group mention decides WHO the message wakes up (GroupMentionRouter).
///
/// Picking one inserts the readable `@名字`; `send()` encodes that to the
/// canonical `<@id>` against the live roster. The composer is a plain
/// UITextView and cannot draw a chip, so this is the same split Telegram uses
/// for a typed @username.
struct GroupMentionCandidate: Identifiable, Equatable {
    /// Agent id, or `Self.everyoneId` for the whole room.
    let id: String
    /// What gets typed after the `@`.
    let handle: String
    let display: String
    let emoji: String
    let subtitle: String

    static let everyoneId = "__everyone__"
    var isEveryone: Bool { id == Self.everyoneId }
}

extension AIChatViewModel {

    /// Group members matching the active `@` query, `@所有人` first.
    ///
    /// Empty in every 1:1 conversation, which is what keeps the existing file
    /// picker untouched: the group rows simply do not exist there.
    var filteredGroupMentions: [GroupMentionCandidate] {
        guard isGroupTranscript, !groupMembers.isEmpty else { return [] }
        let query = mentionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var rows: [GroupMentionCandidate] = [
            GroupMentionCandidate(
                id: GroupMentionCandidate.everyoneId,
                handle: "所有人",
                display: String(localized: "所有人"),
                emoji: "📣",
                subtitle: String(localized: "群里每个人都会依次发言")
            )
        ]
        rows += groupMembers.map { member in
            GroupMentionCandidate(
                id: member.id,
                handle: member.name,
                display: member.name,
                emoji: member.emoji.isEmpty ? "🤖" : member.emoji,
                subtitle: member.title.isEmpty ? member.summary : member.title
            )
        }

        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.handle.lowercased().hasPrefix(query) || row.display.lowercased().contains(query)
        }
    }

    /// Insert `@<handle> ` into the input, replacing the active `@<token>`.
    ///
    /// Same span arithmetic as `selectMention` — from the `@` up to the next
    /// whitespace — so the two paths cannot disagree about what they replaced.
    func selectGroupMention(_ candidate: GroupMentionCandidate) {
        replaceActiveMentionToken(with: "@\(candidate.handle) ")
    }

    /// Rows to render in the menu. Recomputed on each access so that
    /// `FileMentionIndex.entries` / `mentionFilter` changes propagate without
    /// extra plumbing.
    var filteredMentionEntries: [FileMentionEntry] {
        let f = mentionFilter
        let result = FileMentionIndex.shared.matches(for: f)
        #if DEBUG
        let basenames = result.prefix(6).map { $0.basename }.joined(separator: ",")
        print("[MentionRead] filteredMentionEntries ACCESS filter=\"\(f)\" count=\(result.count) first6=[\(basenames)]")
        #endif
        return result
    }

    /// Called from `inputText.didSet` and `inputCaret.didSet`. Detects whether
    /// the caret is inside an `@<token>` and toggles the menu accordingly.
    func updateMentionMenuState() {
        // Never show alongside the slash menu.
        if showSlashMenu {
            if showMentionMenu {
                mentionPickerLogger.info("[MentionPicker] event=dismiss reason=slashMenuOpen show=true→false")
                dismissMentionMenu()
            }
            return
        }
        let text = inputText
        let nsText = text as NSString
        let caret = max(0, min(inputCaret, nsText.length))

        // Walk backwards from caret to find a `@`. Bail on whitespace/newline.
        var anchor = -1
        var idx = caret
        while idx > 0 {
            let prev = idx - 1
            let ch = nsText.character(at: prev)
            let scalar = UnicodeScalar(ch)
            // Stop on whitespace / newline — the token ends there.
            if let s = scalar, CharacterSet.whitespacesAndNewlines.contains(s) { break }
            if ch == UInt16(UnicodeScalar("@").value) {
                // Require `@` to be at start of text or preceded by whitespace,
                // so email-like "foo@bar" doesn't pop the menu.
                if prev == 0 {
                    anchor = prev
                } else {
                    let before = nsText.character(at: prev - 1)
                    if let bs = UnicodeScalar(before), CharacterSet.whitespacesAndNewlines.contains(bs) {
                        anchor = prev
                    }
                }
                break
            }
            idx = prev
        }

        guard anchor >= 0 else {
            // Logging the "text has @ but no anchor found" branch is
            // diagnostically useful for the "why didn't the menu open"
            // report, but if it fires on every keystroke for a message
            // that already contains `@` somewhere it'll spam the log
            // ring. Emit ONLY on the transition `show=true → no anchor`
            // (which is the dismiss path) plus a rare-event sampling
            // when text has `@` but show was already false. Most
            // keystrokes that hit this branch are no-ops.
            if showMentionMenu {
                let preview = String(inputText.prefix(60))
                mentionPickerLogger.info("[MentionPicker] event=dismiss reason=caretLeftAnchor inputLen=\(nsText.length) caretPos=\(caret) textPrefix=\"\(preview)\"")
                dismissMentionMenu()
            }
            return
        }
        // Filter = substring between `@` and caret.
        let filterRange = NSRange(location: anchor + 1, length: caret - (anchor + 1))
        let filter = nsText.substring(with: filterRange)

        mentionAnchor = anchor
        mentionFilter = filter
        if !showMentionMenu {
            // Pre-select the first row so a hardware-keyboard user can hit
            // Return immediately to insert the top match. The selection
            // also tells the UI which row to highlight on open. Up/Down
            // arrows then walk through the list as expected.
            mentionSelectedIndex = 0
            // Defer `showMentionMenu = true` until scanning either finishes
            // OR a short grace window elapses. Otherwise the popup's
            // entrance transition (0.18s) runs concurrently with the
            // entries refilling, producing a visual mismatch where the
            // rows pop into position while the card is still mid-slide
            // ("text first, card catches up" feel reported by user).
            //
            // Path:
            //   - cache fresh + entries non-empty → show immediately
            //   - otherwise → kick off refresh, then show:
            //       * as soon as scan finishes, OR
            //       * after a 250ms grace timeout if scan is slow (so
            //         the user still gets feedback)
            let index = FileMentionIndex.shared
            let entriesCount = index.entries.count
            let isScanning = index.isScanning
            mentionPickerLogger.info("[MentionPicker] event=trigger anchor=\(anchor) caretPos=\(caret) filter=\"\(filter)\" entries=\(entriesCount) scanning=\(isScanning) sid=\(self.sessionId ?? "<nil>")")
            if !isScanning && !index.entries.isEmpty {
                showMentionMenu = true
                mentionPickerLogger.info("[MentionPicker] event=present mode=immediate entries=\(entriesCount)")
                index.refreshIfNeeded(sessionId: sessionId)
            } else {
                index.refreshIfNeeded(sessionId: sessionId)
                if index.isScanning {
                    mentionPickerLogger.info("[MentionPicker] event=present mode=deferred scanning=true awaiting scan-finish or 250ms grace")
                    let deferredAnchor = anchor
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Race: scan finish or 250ms grace
                        let waitStart = Date()
                        let scanFinish = Task<Void, Never> {
                            while FileMentionIndex.shared.isScanning {
                                try? await Task.sleep(nanoseconds: 30_000_000)
                                if Task.isCancelled { return }
                            }
                        }
                        let grace = Task<Void, Never> {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                        _ = await withTaskGroup(of: Void.self) { group in
                            group.addTask { await scanFinish.value }
                            group.addTask { await grace.value }
                            await group.next()
                            group.cancelAll()
                        }
                        let waitMs = Int(Date().timeIntervalSince(waitStart) * 1000)
                        let stillScanning = FileMentionIndex.shared.isScanning
                        let nowEntries = FileMentionIndex.shared.entries.count
                        // Preserve original guard semantics: `mentionAnchor` is
                        // a non-optional Int initialized to -1, so the original
                        // `!= nil` check was always true. We log when the @
                        // context drifted (anchor differs from the trigger we
                        // recorded) but still set show=true to match prior
                        // behavior exactly — this commit is diagnostic-only.
                        if self.mentionAnchor != deferredAnchor {
                            mentionPickerLogger.info("[MentionPicker] event=deferredAnchorDrift waitMs=\(waitMs) anchorChanged from=\(deferredAnchor) to=\(self.mentionAnchor) stillScanning=\(stillScanning) entries=\(nowEntries)")
                        }
                        self.showMentionMenu = true
                        mentionPickerLogger.info("[MentionPicker] event=presentDeferred waitMs=\(waitMs) stillScanning=\(stillScanning) entries=\(nowEntries)")
                    }
                } else {
                    showMentionMenu = true
                    mentionPickerLogger.info("[MentionPicker] event=present mode=eager-empty entries=\(entriesCount) scanning=false")
                }
            }
        } else {
            // Menu is already open and the filter just changed: reset
            // selection to the top so the now-#1 row is the one Return
            // will commit (otherwise the index can point past the end of
            // a shrunk filtered list).
            // Picker already open and filter just changed — fires on every
            // keystroke while typing the query. Intentionally NOT logging
            // here to avoid log spam; the open-time trigger event already
            // captured the entry, and dismiss/select cover the exit.
            let count = filteredMentionEntries.count
            if count == 0 {
                mentionSelectedIndex = -1
            } else if mentionSelectedIndex < 0 || mentionSelectedIndex >= count {
                mentionSelectedIndex = 0
            }
        }
    }

    func dismissMentionMenu() {
        let wasShown = showMentionMenu
        showMentionMenu = false
        mentionSelectedIndex = -1
        mentionFilter = ""
        mentionAnchor = -1
        if wasShown {
            mentionPickerLogger.info("[MentionPicker] event=dismissed wasShown=true")
        }
    }

    func mentionMenuUp() {
        let count = filteredMentionEntries.count
        guard count > 0 else { return }
        if mentionSelectedIndex <= 0 {
            mentionSelectedIndex = count - 1
        } else {
            mentionSelectedIndex -= 1
        }
    }

    func mentionMenuDown() {
        let count = filteredMentionEntries.count
        guard count > 0 else { return }
        if mentionSelectedIndex >= count - 1 {
            mentionSelectedIndex = 0
        } else {
            mentionSelectedIndex += 1
        }
    }

    /// Commit the highlighted mention (or the first match) into the input.
    /// Returns true if a selection was applied.
    @discardableResult
    func executeSelectedMention() -> Bool {
        let entries = filteredMentionEntries
        guard !entries.isEmpty else { return false }
        let idx = (mentionSelectedIndex >= 0 && mentionSelectedIndex < entries.count)
            ? mentionSelectedIndex : 0
        selectMention(entries[idx])
        return true
    }

    /// Insert `entry.linuxPath` into the input, replacing the active `@<token>`.
    /// Leaves a trailing space so the user can keep typing.
    func selectMention(_ entry: FileMentionEntry) {
        mentionPickerLogger.info("[MentionPicker] event=select basename=\(entry.basename) pathLen=\((entry.linuxPath as NSString).length) candidatesAtSelect=\(self.filteredMentionEntries.count)")
        replaceActiveMentionToken(with: "@\(entry.linuxPath) ")
    }

    /// Replace the active `@<token>` with `replacement`, leaving the caret
    /// after it. Shared by the file picker and the group-member picker so the
    /// two can never disagree about what span an `@` owns.
    private func replaceActiveMentionToken(with replacement: String) {
        guard mentionAnchor >= 0 else { return }
        let nsText = inputText as NSString
        let anchor = min(mentionAnchor, nsText.length)
        // Replacement span: from `@` up to the next whitespace (or end).
        var endOffset = anchor + 1
        while endOffset < nsText.length {
            let ch = nsText.character(at: endOffset)
            if let s = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) { break }
            endOffset += 1
        }
        let newText = nsText.replacingCharacters(
            in: NSRange(location: anchor, length: endOffset - anchor),
            with: replacement
        )
        let newCaret = anchor + (replacement as NSString).length
        // Dismiss *before* text mutation so `updateMentionMenuState` in the
        // didSet doesn't re-open on the fresh input.
        dismissMentionMenu()
        inputText = newText
        pendingCaret = newCaret
    }

}
