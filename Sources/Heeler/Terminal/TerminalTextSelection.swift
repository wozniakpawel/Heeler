import Foundation

/// A cell in the visible grid, 1-based like ``TerminalGridPointMapper``.
struct TerminalGridCell: Hashable, Comparable, Sendable {
    var row: Int
    var column: Int

    static func < (lhs: TerminalGridCell, rhs: TerminalGridCell) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A run of cells the user has selected on the visible grid, in reading
/// order: from `start` to `end` inclusive, wrapping through the full width of
/// every row between them, the way a text selection reads rather than a block.
///
/// `anchor` is the end the gesture holds still and `focus` the one it moves.
/// A word selection remembers the word it started from, so dragging past
/// either side of the word extends from the word's far edge, as iOS does.
struct TerminalGridSelection: Equatable, Sendable {
    var anchor: TerminalGridCell
    var focus: TerminalGridCell
    /// The cells first selected, when the selection began on a word or link.
    var origin: ClosedRange<TerminalGridCell>?

    init(anchor: TerminalGridCell, focus: TerminalGridCell, origin: ClosedRange<TerminalGridCell>? = nil) {
        self.anchor = anchor
        self.focus = focus
        self.origin = origin
    }

    /// A selection covering exactly one span of cells.
    init(span: TerminalGridSpan) {
        let start = TerminalGridCell(row: span.row, column: span.columns.lowerBound)
        let end = TerminalGridCell(row: span.row, column: span.columns.upperBound)
        self.init(anchor: start, focus: end, origin: start...end)
    }

    /// A selection covering the cells of several spans, first to last.
    init?(spans: [TerminalGridSpan]) {
        guard let first = spans.min(by: { ($0.row, $0.columns.lowerBound) < ($1.row, $1.columns.lowerBound) }),
            let last = spans.max(by: { ($0.row, $0.columns.upperBound) < ($1.row, $1.columns.upperBound) })
        else { return nil }
        let start = TerminalGridCell(row: first.row, column: first.columns.lowerBound)
        let end = TerminalGridCell(row: last.row, column: last.columns.upperBound)
        self.init(anchor: start, focus: end, origin: start...end)
    }

    var start: TerminalGridCell { min(anchor, focus) }
    var end: TerminalGridCell { max(anchor, focus) }

    func contains(_ cell: TerminalGridCell) -> Bool {
        cell >= start && cell <= end
    }

    /// Moves the selection's far end to `cell`. Dragging back across the
    /// origin flips which end is held: the origin never shrinks.
    mutating func extend(to cell: TerminalGridCell) {
        if let origin {
            if cell < origin.lowerBound {
                anchor = origin.upperBound
                focus = cell
            } else if cell > origin.upperBound {
                anchor = origin.lowerBound
                focus = cell
            } else {
                anchor = origin.lowerBound
                focus = origin.upperBound
            }
        } else {
            focus = cell
        }
    }

    /// Moves `end` (the side nearer the handle the user grabbed) to `cell`
    /// without letting the two ends cross.
    mutating func move(_ which: SelectionEnd, to cell: TerminalGridCell) {
        let start = start
        let end = end
        origin = nil
        switch which {
        case .start:
            anchor = end
            focus = min(cell, end)
        case .end:
            anchor = start
            focus = max(cell, start)
        }
    }

    enum SelectionEnd: Equatable, Sendable {
        case start
        case end
    }

    /// The cells on each row, for a grid `columns` wide. Columns past the
    /// grid, which an estimated cell width can produce, fold onto its edge.
    func spans(columns: Int) -> [TerminalGridSpan] {
        let start = start
        let end = end
        guard columns > 0 else { return [] }
        if start.row == end.row {
            return [TerminalGridSpan(row: start.row, columns: start.column...max(end.column, start.column))]
        }
        var spans = [TerminalGridSpan(row: start.row, columns: min(start.column, columns)...columns)]
        for row in (start.row + 1)..<end.row {
            spans.append(TerminalGridSpan(row: row, columns: 1...columns))
        }
        spans.append(TerminalGridSpan(row: end.row, columns: 1...max(end.column, 1)))
        return spans
    }
}

/// Reads selections out of the visible rows.
enum TerminalSelectionText {
    /// Characters that end a word, as Ghostty's double-click does: blanks,
    /// quotes, brackets and the separators a shell line is punctuated with.
    /// Slashes, dots and dashes stay inside, so a path or hostname is one word.
    static let wordBoundaries: Set<Character> = [
        "'", "\"", "`", "|", ":", ";", ",", "(", ")", "[", "]", "{", "}", "<", ">", "│",
    ]

    static func isWordBoundary(_ character: Character) -> Bool {
        character.isWhitespace || wordBoundaries.contains(character)
    }

    /// The word covering `column` on `row`, or the cell itself on a blank or
    /// a boundary character.
    static func wordSpan(in row: TerminalViewportRow, atColumn column: Int, rowIndex: Int) -> TerminalGridSpan {
        guard let index = row.characterIndex(atColumn: column),
            !isWordBoundary(row.characters[index])
        else {
            return TerminalGridSpan(row: rowIndex, columns: column...column)
        }
        var first = index
        while first > 0, !isWordBoundary(row.characters[first - 1]) {
            first -= 1
        }
        var last = index
        while last + 1 < row.characters.count, !isWordBoundary(row.characters[last + 1]) {
            last += 1
        }
        return TerminalGridSpan(
            row: rowIndex,
            columns: row.cellStarts[first]...row.lastCell(ofCharacterAt: last))
    }

    /// The selected text. Rows are joined with a line break, except where a
    /// row runs to the edge and continues on the next: that fold is Ghostty's
    /// soft wrap, and the copied line stays whole.
    static func text(of selection: TerminalGridSelection, in grid: TerminalViewportRows) -> String {
        var result = ""
        let spans = selection.spans(columns: grid.columns)
        for (index, span) in spans.enumerated() {
            guard let row = grid.row(span.row) else { continue }
            result += row.text(inColumns: span.columns)
            if index + 1 < spans.count, !grid.wraps(span.row) {
                result += "\n"
            }
        }
        return result
    }

    /// Where the selection sits in the `\n`-joined viewport text, in UTF-16
    /// units, for a text view showing that same text.
    static func utf16Range(of selection: TerminalGridSelection, in grid: TerminalViewportRows) -> NSRange? {
        guard let startRow = grid.row(selection.start.row), let endRow = grid.row(selection.end.row) else {
            return nil
        }
        var location = 0
        for row in 1..<max(selection.start.row, 1) {
            location += (grid.row(row)?.utf16Count ?? 0) + 1
        }
        location += startRow.utf16Offset(atColumn: selection.start.column)
        var end = 0
        for row in 1..<max(selection.end.row, 1) {
            end += (grid.row(row)?.utf16Count ?? 0) + 1
        }
        // Past the whole character covering the end cell, so a wide character
        // selected by its first cell stays in, as it does in the copied text.
        let endColumn = endRow.characterIndex(atColumn: selection.end.column)
            .map { endRow.lastCell(ofCharacterAt: $0) } ?? selection.end.column
        end += endRow.utf16Offset(atColumn: endColumn + 1)
        return NSRange(location: location, length: max(end - location, 0))
    }
}
