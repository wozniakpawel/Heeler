import CoreGraphics
import Foundation
import Testing

@testable import Heeler

/// The in-place grid selection: how it grows, what it reads, where it draws.
@Suite("Terminal text selection")
struct TerminalTextSelectionTests {
    private static func grid(_ rows: [String], columns: Int) -> TerminalViewportRows {
        TerminalViewportRows(
            rows: rows.map { TerminalViewportRow($0.padding(toLength: columns, withPad: " ", startingAt: 0)) },
            columns: columns)
    }

    private static func cell(_ row: Int, _ column: Int) -> TerminalGridCell {
        TerminalGridCell(row: row, column: column)
    }

    @Test func aWordIsBoundedByBlanksAndSeparators() {
        let row = TerminalViewportRow("cd /usr/local/bin; echo \"hi there\" |")
        #expect(TerminalSelectionText.wordSpan(in: row, atColumn: 8, rowIndex: 3)
            == TerminalGridSpan(row: 3, columns: 4...17))
        #expect(TerminalSelectionText.wordSpan(in: row, atColumn: 1, rowIndex: 3)
            == TerminalGridSpan(row: 3, columns: 1...2))
        // A blank or a separator selects just its own cell.
        #expect(TerminalSelectionText.wordSpan(in: row, atColumn: 3, rowIndex: 3)
            == TerminalGridSpan(row: 3, columns: 3...3))
        #expect(TerminalSelectionText.wordSpan(in: row, atColumn: 18, rowIndex: 3)
            == TerminalGridSpan(row: 3, columns: 18...18))
        #expect(TerminalSelectionText.wordSpan(in: row, atColumn: 60, rowIndex: 3)
            == TerminalGridSpan(row: 3, columns: 60...60))
    }

    @Test func spansRunInReadingOrderAcrossRows() {
        let selection = TerminalGridSelection(anchor: Self.cell(3, 7), focus: Self.cell(1, 4))
        #expect(selection.start == Self.cell(1, 4))
        #expect(selection.end == Self.cell(3, 7))
        #expect(selection.spans(columns: 10) == [
            TerminalGridSpan(row: 1, columns: 4...10),
            TerminalGridSpan(row: 2, columns: 1...10),
            TerminalGridSpan(row: 3, columns: 1...7),
        ])
        #expect(selection.contains(Self.cell(2, 1)))
        #expect(!selection.contains(Self.cell(1, 3)))
        #expect(!selection.contains(Self.cell(3, 8)))
    }

    @Test func draggingExtendsFromTheFarSideOfTheWord() {
        var selection = TerminalGridSelection(span: TerminalGridSpan(row: 2, columns: 5...8))
        selection.extend(to: Self.cell(2, 12))
        #expect(selection.start == Self.cell(2, 5) && selection.end == Self.cell(2, 12))
        selection.extend(to: Self.cell(1, 2))
        #expect(selection.start == Self.cell(1, 2) && selection.end == Self.cell(2, 8))
        selection.extend(to: Self.cell(2, 6))
        #expect(selection.start == Self.cell(2, 5) && selection.end == Self.cell(2, 8))
    }

    @Test func handlesMoveTheirOwnEndWithoutCrossing() {
        var selection = TerminalGridSelection(span: TerminalGridSpan(row: 2, columns: 5...8))
        selection.move(.end, to: Self.cell(3, 2))
        #expect(selection.start == Self.cell(2, 5) && selection.end == Self.cell(3, 2))
        selection.move(.start, to: Self.cell(2, 7))
        #expect(selection.start == Self.cell(2, 7) && selection.end == Self.cell(3, 2))
        selection.move(.start, to: Self.cell(3, 9))
        #expect(selection.start == Self.cell(3, 2) && selection.end == Self.cell(3, 2))
    }

    @Test func aLinkSelectionCoversEverySpanOfTheLink() {
        let selection = TerminalGridSelection(spans: [
            TerminalGridSpan(row: 1, columns: 5...20),
            TerminalGridSpan(row: 2, columns: 1...9),
        ])
        #expect(selection?.start == Self.cell(1, 5))
        #expect(selection?.end == Self.cell(2, 9))
        #expect(TerminalGridSelection(spans: []) == nil)
    }

    @Test func copiedTextJoinsWrappedRowsAndBreaksTheOthers() {
        let grid = Self.grid(["$ echo abcde", "fghij", "next line"], columns: 12)
        let whole = TerminalGridSelection(anchor: Self.cell(1, 1), focus: Self.cell(3, 12))
        #expect(TerminalSelectionText.text(of: whole, in: grid) == "$ echo abcdefghij\nnext line")

        let partial = TerminalGridSelection(anchor: Self.cell(1, 8), focus: Self.cell(2, 2))
        #expect(TerminalSelectionText.text(of: partial, in: grid) == "abcdefg")
    }

    @Test func theSelectionMapsOntoTheJoinedViewportText() {
        let grid = Self.grid(["ab日c", "second"], columns: 6)
        // "ab日c  \nsecond": row 1 is 6 UTF-16 units plus the newline.
        let selection = TerminalGridSelection(anchor: Self.cell(1, 3), focus: Self.cell(2, 3))
        #expect(TerminalSelectionText.utf16Range(of: selection, in: grid) == NSRange(location: 2, length: 8))
        let single = TerminalGridSelection(span: TerminalGridSpan(row: 2, columns: 2...4))
        #expect(TerminalSelectionText.utf16Range(of: single, in: grid) == NSRange(location: 8, length: 3))
    }

    @Test func gridRectsInvertTheCellMapping() {
        let mapper = TerminalGridPointMapper(
            viewSize: CGSize(width: 84, height: 90),
            cellSize: CGSize(width: 10, height: 20),
            columns: 8,
            rows: 4,
            scale: 2)
        let rect = mapper.rect(for: TerminalGridSpan(row: 2, columns: 3...5))
        #expect(rect == CGRect(x: 22.5, y: 22.5, width: 30, height: 20))
        #expect(mapper.cell(at: CGPoint(x: rect.minX + 1, y: rect.minY + 1)).map { [$0.column, $0.row] } == [3, 2])
        #expect(mapper.cell(at: CGPoint(x: rect.maxX - 1, y: rect.maxY - 1)).map { [$0.column, $0.row] } == [5, 2])
    }
}
