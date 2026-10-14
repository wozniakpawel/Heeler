import Foundation

/// A web link printed in the visible grid, with the cells it occupies.
struct TerminalViewportLink: Equatable, Sendable {
    /// The URL exactly as printed.
    let target: String
    /// The cells the link covers, one span per row it runs across.
    let spans: [TerminalGridSpan]

    func contains(row: Int, column: Int) -> Bool {
        spans.contains { $0.contains(row: row, column: column) }
    }
}

/// Finds the web link under a touched cell from the viewport text alone.
///
/// Ghostty's own link detection is only reachable through pointer hover and
/// a modifier click, neither of which a finger produces. The visible rows are
/// read instead and the tapped row is matched together with the rows it wraps
/// onto, so a long URL that folds across a narrow phone grid is still one
/// link. Only `http` and `https` targets are recognized; `TerminalLinkPolicy`
/// still decides whether one may open.
enum TerminalLinkHitTest {
    /// Ghostty's URL character class, restricted to web schemes. An optional
    /// bracketed suffix keeps `wiki/Rust_(video_game)` whole while a URL
    /// written inside parentheses still stops before the closing one.
    private static let pattern =
        #"https?://(?:\[[0-9A-Fa-f:.]+\](?::[0-9]+)?|[\w\-.~:/?#@!$&*+,;=%]+(?:[(\[]\w*[)\]])?)+"#
    private static let expression = try? NSRegularExpression(pattern: pattern)
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\""]

    /// Every web link in the logical line that includes `row`.
    static func links(in grid: TerminalViewportRows, row: Int) -> [TerminalViewportLink] {
        guard let expression, let lineRows = grid.logicalLineRows(containing: row) else { return [] }

        // The line's characters in order, each remembering its cells, so a
        // UTF-16 match range maps back onto the grid.
        var characters: [Character] = []
        var spansByCharacter: [TerminalGridSpan] = []
        for lineRow in lineRows {
            guard let rowText = grid.row(lineRow) else { continue }
            for (index, character) in rowText.characters.enumerated() {
                characters.append(character)
                spansByCharacter.append(TerminalGridSpan(
                    row: lineRow,
                    columns: rowText.cellStarts[index]...rowText.lastCell(ofCharacterAt: index)))
            }
        }
        let line = String(characters)
        var utf16Starts: [Int] = []
        var offset = 0
        for character in characters {
            utf16Starts.append(offset)
            offset += character.utf16.count
        }

        var links: [TerminalViewportLink] = []
        let nsLine = line as NSString
        for match in expression.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            guard let firstIndex = utf16Starts.firstIndex(of: match.range.location) else { continue }
            var lastIndex = firstIndex
            while lastIndex + 1 < utf16Starts.count,
                utf16Starts[lastIndex + 1] < NSMaxRange(match.range)
            {
                lastIndex += 1
            }
            lastIndex = trimmedEnd(of: characters, from: firstIndex, through: lastIndex)
            guard lastIndex >= firstIndex else { continue }
            let target = String(characters[firstIndex...lastIndex])
            guard target.count > "https://".count else { continue }
            links.append(TerminalViewportLink(
                target: target,
                spans: mergeSpans(spansByCharacter[firstIndex...lastIndex])))
        }
        return links
    }

    /// The link whose cells include (`row`, `column`), if any.
    static func link(in grid: TerminalViewportRows, row: Int, column: Int) -> TerminalViewportLink? {
        links(in: grid, row: row).first { $0.contains(row: row, column: column) }
    }

    /// Sentence punctuation after a URL belongs to the prose around it, and
    /// so does a closing bracket with no opening one inside the URL.
    private static func trimmedEnd(
        of characters: [Character], from first: Int, through last: Int
    ) -> Int {
        var end = last
        while end >= first {
            let character = characters[end]
            if trailingPunctuation.contains(character) {
                end -= 1
                continue
            }
            if let opener = closingBrackets[character] {
                let body = characters[first...end]
                let opens = body.count { $0 == opener }
                let closes = body.count { $0 == character }
                if closes > opens {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    private static let closingBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]

    /// Collapses per-character spans into one span per row.
    private static func mergeSpans(_ spans: ArraySlice<TerminalGridSpan>) -> [TerminalGridSpan] {
        var merged: [TerminalGridSpan] = []
        for span in spans {
            if let last = merged.last, last.row == span.row {
                merged[merged.count - 1] = TerminalGridSpan(
                    row: last.row,
                    columns: min(last.columns.lowerBound, span.columns.lowerBound)
                        ...max(last.columns.upperBound, span.columns.upperBound))
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}
