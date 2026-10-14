import Foundation
import Testing

@testable import Heeler

/// Finding the web link under a touched cell from the visible rows alone.
@Suite("Terminal link hit test")
struct TerminalLinkHitTestTests {
    private static func grid(_ rows: [String], columns: Int) -> TerminalViewportRows {
        TerminalViewportRows(
            rows: rows.map { TerminalViewportRow($0.padding(toLength: columns, withPad: " ", startingAt: 0)) },
            columns: columns)
    }

    @Test func aLinkIsHitOnItsOwnCellsAndMissedBesideThem() {
        let grid = Self.grid(["see https://example.com/docs now", "plain text"], columns: 40)

        let hit = TerminalLinkHitTest.link(in: grid, row: 1, column: 12)
        #expect(hit?.target == "https://example.com/docs")
        #expect(hit?.spans == [TerminalGridSpan(row: 1, columns: 5...28)])
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 4) == nil)
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 29) == nil)
        #expect(TerminalLinkHitTest.link(in: grid, row: 2, column: 3) == nil)
        #expect(TerminalLinkHitTest.link(in: grid, row: 3, column: 1) == nil)
    }

    @Test func aLinkFoldedAcrossFullRowsIsOneLink() {
        // 20 columns: the URL runs to the edge of row 1 and continues on row 2.
        let grid = Self.grid(["https://example.com/", "a/b/c?x=1 and more"], columns: 20)

        let hit = TerminalLinkHitTest.link(in: grid, row: 2, column: 3)
        #expect(hit?.target == "https://example.com/a/b/c?x=1")
        #expect(hit?.spans == [
            TerminalGridSpan(row: 1, columns: 1...20),
            TerminalGridSpan(row: 2, columns: 1...9),
        ])
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 20)?.target == hit?.target)
        #expect(TerminalLinkHitTest.link(in: grid, row: 2, column: 11) == nil)
    }

    @Test func aRowThatEndsShortDoesNotContinueOntoTheNext() {
        let grid = Self.grid(["https://example.com", "notpartofit"], columns: 20)
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 3)?.target == "https://example.com")
    }

    @Test func sentencePunctuationAndUnbalancedBracketsAreLeftOut() {
        let grid = Self.grid([
            "Read (https://example.com/a). Then https://en.wikipedia.org/wiki/Rust_(video_game), ok",
        ], columns: 100)

        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 8)?.target == "https://example.com/a")
        #expect(
            TerminalLinkHitTest.link(in: grid, row: 1, column: 40)?.target
                == "https://en.wikipedia.org/wiki/Rust_(video_game)")
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 29) == nil)
    }

    @Test func onlyWebSchemesCount() {
        let grid = Self.grid(["ftp://files.example.com/x http://ok.example"], columns: 60)
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 3) == nil)
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 30)?.target == "http://ok.example")
        #expect(TerminalLinkPolicy.url(for: "http://ok.example") != nil)
    }

    @Test func wideCharactersBeforeALinkShiftItsCells() {
        // "日本" takes four cells, so the URL starts on cell 6.
        let grid = Self.grid(["日本 https://例え.jp/x"], columns: 30)
        let hit = TerminalLinkHitTest.link(in: grid, row: 1, column: 7)
        #expect(hit?.target == "https://例え.jp/x")
        #expect(hit?.spans == [TerminalGridSpan(row: 1, columns: 6...22)])
        #expect(TerminalLinkHitTest.link(in: grid, row: 1, column: 5) == nil)
    }

    @Test func viewportRowsMapCellsToCharacters() {
        let row = TerminalViewportRow("ab日c")
        #expect(row.cellStarts == [1, 2, 3, 5])
        #expect(row.cellCount == 5)
        #expect(row.characterIndex(atColumn: 3) == 2)
        #expect(row.characterIndex(atColumn: 4) == 2)
        #expect(row.characterIndex(atColumn: 5) == 3)
        #expect(row.characterIndex(atColumn: 6) == nil)
        #expect(row.text(inColumns: 2...4) == "b日")
        #expect(row.utf16Offset(atColumn: 5) == 3)
        #expect(!row.isFull(columns: 6))
        #expect(TerminalViewportRow("abcdef").isFull(columns: 6))
        #expect(!TerminalViewportRow("abcde ").isFull(columns: 6))
    }

    @Test func logicalLinesFollowFullRowsBothWays() {
        let grid = Self.grid(["aaaaa", "bbbbb", "cc", "ddddd", "ee"], columns: 5)
        #expect(grid.logicalLineRows(containing: 2) == 1...3)
        #expect(grid.logicalLineRows(containing: 3) == 1...3)
        #expect(grid.logicalLineRows(containing: 4) == 4...5)
        #expect(grid.logicalLineRows(containing: 5) == 4...5)
        #expect(grid.logicalLineRows(containing: 6) == nil)
    }
}
