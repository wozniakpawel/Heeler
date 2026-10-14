import Foundation

/// The keystrokes that turn one committed input line into another: Backspaces
/// for the tail that no longer stands, then the replacement typed after it.
///
/// A PTY has no "replace this range" primitive. iOS dictation revises its live
/// hypothesis in place through `UITextInput.replace(_:withText:)`, and a text
/// view may replace characters anywhere in the line, so an edit reaches the
/// remote line editor as the shortest retype from the first changed character.
struct TerminalLineEdit: Equatable, Sendable {
    /// Composed characters to delete from the end of the current line, one
    /// Backspace each.
    let backspaces: Int
    /// Text to type once the deletions have landed.
    let text: String

    var isEmpty: Bool { backspaces == 0 && text.isEmpty }

    /// The edit that turns `current` into `target`.
    static func transition(from current: String, to target: String) -> TerminalLineEdit {
        let sharedPrefixCount = zip(current, target).prefix { $0 == $1 }.count
        return TerminalLineEdit(
            backspaces: current.count - sharedPrefixCount,
            text: String(target.dropFirst(sharedPrefixCount)))
    }

    /// `text` split at its line breaks. Each break between two segments is one
    /// Return key: dictated "new line" must reach the shell the way the soft
    /// keyboard's own Return does, not as a literal newline inside a paste.
    var typedSegments: [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }
}

/// A dictation session on a terminal surface: the committed line as it stood
/// when the keyboard switched to dictation. Edits the keyboard makes while it
/// lasts land in the local document only; the PTY hears the difference once,
/// when dictation ends.
///
/// Why: iOS inserts each hypothesis as it is recognized and then revises it
/// with `replace(_:withText:)`. Sent live, every revision retypes the phrase
/// after the previous one and the shell ends up with "Hello Hello world Hello
/// world to" style gibberish. Buffering also keeps the hypothesis churn off a
/// TUI that redraws on every keystroke.
struct TerminalDictationTransaction: Equatable, Sendable {
    let baseline: String

    /// What reaches the PTY for a document that now reads `document`.
    ///
    /// A fresh line gets no leading blank: iOS spaces a dictated sentence off
    /// the text before it, and with nothing before it the blank would only
    /// hide the command from a shell's history (`HISTCONTROL=ignorespace`).
    func edit(for document: String) -> TerminalLineEdit {
        var target = document
        if baseline.isEmpty, target.first == " " {
            target.removeFirst()
        }
        return TerminalLineEdit.transition(from: baseline, to: target)
    }

    /// The text dictation has put after the baseline, or nil when the
    /// document no longer starts with the baseline.
    func liveText(in document: String) -> String? {
        guard document.hasPrefix(baseline) else { return nil }
        return String(document.dropFirst(baseline.count))
    }
}
