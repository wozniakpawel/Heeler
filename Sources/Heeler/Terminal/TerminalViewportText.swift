import Foundation

/// How many grid cells a character occupies when Ghostty draws it.
///
/// An approximation of the renderer's own width table: East Asian wide and
/// fullwidth characters and emoji take two cells, everything else one. It is
/// used to map a touched cell back to a character in a row's text, so an
/// error only ever moves a hit by a cell on rows that mix scripts.
enum TerminalCellWidth {
    static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            return 2
        }
        // A keycap or text-presentation symbol forced to emoji by VS16.
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }),
            scalar.properties.isEmoji
        {
            return 2
        }
        return isWide(scalar) ? 2 : 1
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,  // Hangul Jamo
            0x2E80...0x303E,  // CJK radicals, Kangxi, ideographic description, CJK symbols
            0x3041...0x33FF,  // Hiragana, Katakana, Bopomofo, CJK compatibility
            0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xA000...0xA4CF,  // Yi
            0xAC00...0xD7A3,  // Hangul syllables
            0xF900...0xFAFF,  // CJK compatibility ideographs
            0xFE30...0xFE4F,  // CJK compatibility forms
            0xFF00...0xFF60,  // Fullwidth forms
            0xFFE0...0xFFE6,
            0x1F300...0x1F64F,  // Pictographs, emoticons
            0x1F900...0x1F9FF,  // Supplemental symbols and pictographs
            0x20000...0x3FFFD:  // CJK Unified Ideographs Extensions B–F
            return true
        default:
            return false
        }
    }
}

/// One visible terminal row, as `readViewportText()` reads it, with each
/// character placed on the 1-based cell it starts at.
struct TerminalViewportRow: Equatable, Sendable {
    let characters: [Character]
    /// The first cell of each character in `characters`.
    let cellStarts: [Int]
    /// Cells the text covers; trailing blanks count, because the reader pads
    /// a row to its full width.
    let cellCount: Int

    init(_ text: String) {
        var characters: [Character] = []
        var cellStarts: [Int] = []
        var nextCell = 1
        for character in text {
            characters.append(character)
            cellStarts.append(nextCell)
            nextCell += TerminalCellWidth.width(of: character)
        }
        self.characters = characters
        self.cellStarts = cellStarts
        cellCount = nextCell - 1
    }

    var text: String { String(characters) }

    /// The row runs to the last column with a visible character there, so the
    /// line may continue on the next row. The reader does not say which rows
    /// wrap; this is the only sign it leaves.
    func isFull(columns: Int) -> Bool {
        guard columns > 0, cellCount >= columns, let last = characters.last else { return false }
        return !last.isWhitespace
    }

    /// The character covering `column`, or nil past the end of the text.
    func characterIndex(atColumn column: Int) -> Int? {
        guard column >= 1, let first = cellStarts.first, column >= first else { return nil }
        var index = 0
        for (candidate, start) in cellStarts.enumerated() where start <= column {
            index = candidate
        }
        let end = cellStarts[index] + TerminalCellWidth.width(of: characters[index]) - 1
        return column <= end ? index : nil
    }

    /// The last cell of the character at `index`.
    func lastCell(ofCharacterAt index: Int) -> Int {
        cellStarts[index] + TerminalCellWidth.width(of: characters[index]) - 1
    }

    /// The characters whose cells intersect `columns`, without the blanks a
    /// padded row carries after its last visible character.
    func text(inColumns columns: ClosedRange<Int>) -> String {
        var result = ""
        for (index, character) in characters.enumerated() {
            let start = cellStarts[index]
            let end = lastCell(ofCharacterAt: index)
            guard end >= columns.lowerBound, start <= columns.upperBound else { continue }
            result.append(character)
        }
        while let last = result.last, last == " " {
            result.removeLast()
        }
        return result
    }

    /// UTF-16 offset of the character starting at or after `column`, or the
    /// text's length when none does.
    func utf16Offset(atColumn column: Int) -> Int {
        var offset = 0
        for (index, character) in characters.enumerated() {
            if lastCell(ofCharacterAt: index) >= column { return offset }
            offset += character.utf16.count
        }
        return offset
    }

    var utf16Count: Int { characters.reduce(0) { $0 + $1.utf16.count } }
}

/// The visible grid as rows of text. Rows are indexed from 1, like the cells
/// ``TerminalGridPointMapper`` produces.
struct TerminalViewportRows: Equatable, Sendable {
    let rows: [TerminalViewportRow]
    let columns: Int

    /// `viewportText` is `readViewportText()`'s output: one line per row,
    /// joined with `\n`, each padded to the grid width.
    init(viewportText: String, columns: Int) {
        rows = viewportText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { TerminalViewportRow(String($0)) }
        self.columns = columns
    }

    init(rows: [TerminalViewportRow], columns: Int) {
        self.rows = rows
        self.columns = columns
    }

    var rowCount: Int { rows.count }

    func row(_ row: Int) -> TerminalViewportRow? {
        guard row >= 1, row <= rows.count else { return nil }
        return rows[row - 1]
    }

    /// Whether `row` continues onto the next one.
    func wraps(_ row: Int) -> Bool {
        guard row < rows.count, let current = self.row(row) else { return false }
        return current.isFull(columns: columns)
    }

    /// The rows that print as one line with `row`: back to the first row that
    /// does not continue a previous one, forward while rows keep running to
    /// the edge, bounded so a screen of full rows stays a cheap read.
    func logicalLineRows(containing row: Int, limit: Int = 8) -> ClosedRange<Int>? {
        guard self.row(row) != nil else { return nil }
        var first = row
        while first > 1, first > row - limit, wraps(first - 1) {
            first -= 1
        }
        var last = row
        while last < rows.count, last < row + limit, wraps(last) {
            last += 1
        }
        return first...last
    }
}

/// A run of cells on one row, both ends inclusive and 1-based.
struct TerminalGridSpan: Equatable, Hashable, Sendable {
    let row: Int
    let columns: ClosedRange<Int>

    func contains(row: Int, column: Int) -> Bool {
        self.row == row && columns.contains(column)
    }
}
