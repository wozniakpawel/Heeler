import Foundation
import Testing
import UIKit

@testable import Heeler

/// iOS dictation edits the terminal's text-input document while it listens;
/// the PTY must hear the finished sentence once.
@MainActor
@Suite("Terminal dictation", .serialized)
struct TerminalDictationTests {
    @Test func liveHypothesesStayOffThePTYUntilTheResultArrives() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal
        terminal.dictationInputModeOverride = true

        (terminal as UIKeyInput).insertText("Hello")
        #expect(terminal.isDictating)
        #expect(fixture.documentText == "Hello")
        #expect(try await fixture.drain().isEmpty)

        // The keyboard revises its hypothesis in place.
        terminal.replace(try fixture.wholeDocument(), withText: "Hello world")
        #expect(fixture.documentText == "Hello world")
        #expect(try await fixture.drain().isEmpty)

        // UIKit takes the live text out before handing over the final result.
        terminal.replace(try fixture.wholeDocument(), withText: "")
        terminal.insertDictationText("Hello world")
        #expect(!terminal.isDictating)
        #expect(fixture.documentText == "Hello world")
        #expect(try await fixture.drain() == Data("Hello world".utf8))

        // The echo of the sent text was pre-recorded, not recorded twice.
        #expect(fixture.documentText == "Hello world")
    }

    @Test func aResultMatchingTheLiveTextIsNotTypedTwice() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal
        terminal.dictationInputModeOverride = true

        (terminal as UIKeyInput).insertText(" ")
        (terminal as UIKeyInput).insertText("Hello world")
        terminal.insertDictationText("Hello world")

        // On an empty line the sentence keeps no leading blank either.
        #expect(try await fixture.drain() == Data("Hello world".utf8))
        #expect(fixture.documentText == "Hello world")
    }

    @Test func dictationAfterTypedTextKeepsItsSpacing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal

        (terminal as UIKeyInput).insertText("echo")
        #expect(try await fixture.drain() == Data("echo".utf8))
        #expect(fixture.documentText == "echo")

        terminal.dictationInputModeOverride = true
        (terminal as UIKeyInput).insertText(" hi")
        terminal.insertDictationText("")
        #expect(try await fixture.drain() == Data(" hi".utf8))
        #expect(fixture.documentText == "echo hi")
    }

    @Test func aDictatedNewLineIsReturn() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal
        terminal.dictationInputModeOverride = true

        (terminal as UIKeyInput).insertText("ls\nls")
        terminal.insertDictationText("")
        #expect(try await fixture.drain() == Data("ls\rls".utf8))
    }

    @Test func leavingDictationModeFlushesAfterTheGracePeriod() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal
        terminal.dictationInputModeOverride = true

        (terminal as UIKeyInput).insertText("Hi")
        terminal.dictationInputModeOverride = false
        NotificationCenter.default.post(
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        #expect(terminal.isDictating)

        try await Task.sleep(for: .milliseconds(1_100))
        #expect(!terminal.isDictating)
        #expect(try await fixture.drain() == Data("Hi".utf8))
    }

    @Test func replacingTypedTextRetypesFromTheFirstChange() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.close() }
        let terminal = fixture.terminal

        (terminal as UIKeyInput).insertText("helo")
        #expect(try await fixture.drain() == Data("helo".utf8))
        #expect(fixture.documentText == "helo")

        terminal.replace(try fixture.wholeDocument(), withText: "hello")
        #expect(try await fixture.drain() == Data([0x7F]) + Data("lo".utf8))
        #expect(fixture.documentText == "hello")
    }

    @Test func lineEditsRetypeOnlyTheChangedTail() {
        #expect(TerminalLineEdit.transition(from: "Hello", to: "Hello world")
            == TerminalLineEdit(backspaces: 0, text: " world"))
        #expect(TerminalLineEdit.transition(from: "Hello there", to: "Hello world")
            == TerminalLineEdit(backspaces: 5, text: "world"))
        #expect(TerminalLineEdit.transition(from: "abc", to: "abc")
            == TerminalLineEdit(backspaces: 0, text: ""))
        #expect(TerminalLineEdit.transition(from: "abc", to: "")
            == TerminalLineEdit(backspaces: 3, text: ""))
        #expect(TerminalLineEdit.transition(from: "", to: "x") == TerminalLineEdit(backspaces: 0, text: "x"))
        // Composed characters count once, like the Backspaces they cost.
        #expect(TerminalLineEdit.transition(from: "e\u{301}a", to: "e\u{301}b").backspaces == 1)
        #expect(TerminalLineEdit(backspaces: 0, text: "one\ntwo\n").typedSegments == ["one", "two", ""])
        #expect(TerminalLineEdit(backspaces: 0, text: "").isEmpty)
    }

    @Test func aDictationOnAnEmptyLineDropsTheLeadingBlankOnly() {
        let fresh = TerminalDictationTransaction(baseline: "")
        #expect(fresh.edit(for: " Hello") == TerminalLineEdit(backspaces: 0, text: "Hello"))
        #expect(fresh.edit(for: " ") == TerminalLineEdit(backspaces: 0, text: ""))
        #expect(fresh.liveText(in: " Hello") == " Hello")

        let continued = TerminalDictationTransaction(baseline: "cd")
        #expect(continued.edit(for: "cd ~/src") == TerminalLineEdit(backspaces: 0, text: " ~/src"))
        #expect(continued.edit(for: "cat") == TerminalLineEdit(backspaces: 1, text: "at"))
        #expect(continued.liveText(in: "cd x") == " x")
        #expect(continued.liveText(in: "x") == nil)
    }

    @MainActor
    private final class Fixture {
        let terminal: HeelerTerminalView
        private var sent = Data()
        private var window: UIWindow?

        private init() {
            terminal = TerminalScreenView.makeConfiguredTerminal()
            terminal.updateCallbacks(
                onSizeChanged: nil,
                onViewportTextChanged: nil,
                onSend: { [weak self] bytes in self?.sent.append(bytes) },
                onScroll: nil,
                onPaste: nil)
        }

        static func make() async throws -> Fixture {
            let fixture = Fixture()
            let controller = UIViewController()
            controller.view = fixture.terminal
            do {
                let window = try await makeTestWindow(
                    frame: CGRect(x: 0, y: 0, width: 402, height: 600),
                    rootViewController: controller)
                fixture.window = window
                controller.view.layoutIfNeeded()
                // insertText reaches Ghostty only while first responder; the
                // gate refuses a bare becomeFirstResponder() until asked.
                fixture.terminal.requestKeyboard()
                _ = try await fixture.drain()
                return fixture
            } catch {
                fixture.close()
                throw error
            }
        }

        func close() {
            terminal.updateCallbacks(
                onSizeChanged: nil,
                onViewportTextChanged: nil,
                onSend: nil,
                onScroll: nil,
                onPaste: nil)
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }

        /// The text-input document UIKit sees.
        var documentText: String? {
            guard let range = try? wholeDocument() else { return nil }
            return terminal.text(in: range)
        }

        func wholeDocument() throws -> UITextRange {
            try #require(
                terminal.textRange(from: terminal.beginningOfDocument, to: terminal.endOfDocument))
        }

        /// Everything sent before Ghostty's reply to a device-attributes
        /// query, which is ordered behind the keys sent so far. The reply
        /// also lets the asynchronous echo recording settle.
        func drain() async throws -> Data {
            terminal.receive(Data("\u{1B}[c".utf8))
            terminal.terminalSession.waitForPendingOutput()
            let marker = Data("\u{1B}[?62;22".utf8)
            let deadline = ContinuousClock.now + .seconds(2)
            while sent.range(of: marker) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let reply = try #require(
                sent.range(of: marker), "Ghostty device attributes reply did not arrive")
            let result = Data(sent[..<reply.lowerBound])
            sent.removeAll(keepingCapacity: true)
            // The echo that records sent text crosses onto the main actor
            // after the send; give it the turn it needs.
            await Task.yield()
            return result
        }
    }
}
