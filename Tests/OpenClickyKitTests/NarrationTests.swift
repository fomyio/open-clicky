import Testing
import Foundation
@testable import OpenClickyKit

/// Written prose and spoken prose are not the same text, and the gap is not cosmetic:
/// "press `cmd+shift+p`" read verbatim is "press backtick c m d plus shift plus p
/// backtick". Nothing here crashes when it is wrong — it just slowly makes the thing
/// unbearable to use, which is exactly the kind of failure a test has to be written for
/// deliberately.
@Suite("Narration")
struct NarrationTests {

    // MARK: - What a listener cannot hear

    @Test("Backticks are dropped and what they wrapped is kept")
    func inlineCodeKeepsItsContent() {
        #expect(Narration.speakable("Press `cmd+shift+p` now") == "Press cmd+shift+p now")
    }

    /// The single worst thing that can arrive at a speaker: long, unpronounceable, and
    /// written to be read rather than heard.
    @Test("A fenced code block is not spoken")
    func codeBlocksAreDropped() {
        let spoken = Narration.speakable("""
            Running this:
            ```swift
            let x = try await client.send(request)
            ```
            then checking the result.
            """)
        #expect(spoken == "Running this: then checking the result.")
    }

    @Test("Markdown emphasis and headings are punctuation, not words")
    func markdownIsStripped() {
        #expect(Narration.speakable("**Done.** That *worked*.") == "Done. That worked.")
        #expect(Narration.speakable("## Result\nIt worked") == "Result It worked")
    }

    @Test("A link says its text, and a bare URL says its host")
    func linksSayTheirLabel() {
        #expect(Narration.speakable("See [the docs](https://example.com/a/b) for more")
                == "See the docs for more")
        #expect(Narration.speakable("Opening https://github.com/a/b now")
                == "Opening github.com now")
    }

    /// Eleven seconds of directory nobody was listening to by the end of. A path is
    /// spoken as the thing at the end of it, which is how a person refers to a file.
    @Test("An absolute path is spoken as the file at the end of it")
    func pathsAreShortened() {
        #expect(Narration.speakable("Editing /Users/someone/Documents/Projects/App/Main.swift")
                == "Editing Main.swift")
        #expect(Narration.speakable("Look in ~/Library/Preferences/com.apple.dock.plist")
                == "Look in com.apple.dock.plist")
    }

    /// A listener has no bullets to see, and without a pause the items run together into
    /// one clause.
    @Test("List markers become sentence breaks")
    func listsBecomeSentences() {
        let spoken = Narration.speakable("""
            I will:
            - open VS Code
            - press the palette
            """)
        #expect(spoken == "I will: . open VS Code . press the palette")
    }

    @Test("Whitespace is collapsed so the synthesiser does not pause oddly")
    func whitespaceIsCollapsed() {
        #expect(Narration.speakable("Line one.\n\n\nLine   two.") == "Line one. Line two.")
    }

    // MARK: - Nothing to say

    /// Nil rather than empty: the caller's decision is "speak or don't", and an empty
    /// string queues an utterance and fires a completion for silence.
    @Test("A turn with nothing sayable in it returns nil", arguments: [
        "", "   ", "\n\n", "```\nlet x = 1\n```", "- \n- \n", "***", "...", "##",
    ])
    func nothingToSayIsNil(prose: String) {
        #expect(Narration.speakable(prose) == nil, "'\(prose)'")
    }

    @Test("Ordinary prose survives untouched")
    func plainProseIsUnchanged() {
        let plain = "Sure, let me bring VS Code to the front."
        #expect(Narration.speakable(plain) == plain)
    }

    // MARK: - Length

    /// The cap is about interruptibility, not economy. A narration that runs for a
    /// minute is one the user has to talk over to stop, and having to interrupt your
    /// assistant to get on with things is the failure this phase exists to avoid.
    @Test("A long turn is clipped to something interruptible")
    func longProseIsClipped() throws {
        let long = String(repeating: "This is a sentence about the thing. ", count: 40)
        let spoken = try #require(Narration.speakable(long))
        #expect(spoken.count <= Narration.budget)
        #expect(spoken.hasSuffix("."), "it should stop at a sentence end when it can")
    }

    /// The one place it must never cut. A synthesiser given half a word says half a
    /// word, and the listener hears a fault rather than an abbreviation.
    @Test("Clipping never cuts a word in half")
    func clippingRespectsWordBoundaries() {
        let words = String(repeating: "antidisestablishmentarianism ", count: 30)
        let clipped = Narration.clipped(words, to: 100)
        #expect(clipped.count <= 101)
        let body = clipped.replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespaces)
        for word in body.split(separator: " ") {
            #expect(word == "antidisestablishmentarianism", "cut mid-word: '\(word)'")
        }
    }

    /// A single long sentence must not be cut back to almost nothing just because it
    /// happened to contain an early full stop.
    @Test("Clipping keeps a useful amount, not just the first clause")
    func clippingKeepsEnough() {
        let text = "Ok. " + String(repeating: "then a much longer continuation ", count: 20)
        let clipped = Narration.clipped(text, to: 200)
        #expect(clipped.count > 100, "clipped back to the first short sentence")
    }

    // MARK: - What it must not do

    /// The narration is the agent's own account of what it is doing. A layer that
    /// paraphrased would be putting statements about the user's machine into its mouth
    /// — the same class of error as a run reporting success it did not earn.
    @Test("It only removes and shortens; it never invents a word")
    func nothingIsInvented() {
        let samples = [
            "Sure, let me bring VS Code to the front.",
            "Opening the command palette now.",
            "That did not work — the window never came forward.",
            "I could not find a Save button in this dialog.",
        ]
        for prose in samples {
            let spoken = Narration.speakable(prose) ?? ""
            for word in spoken.split(separator: " ") where word.count > 3 {
                #expect(prose.contains(word), "'\(word)' was not in what the agent wrote")
            }
        }
    }

    /// It runs on model output, which is not a trusted grammar. Anything at all has to
    /// come back with an answer rather than trapping.
    @Test("Any input at all is survivable", arguments: [
        "```", "``", "[unclosed](", "**", "*", "~/", "/", "//", "///",
        "\u{0}\u{1}", String(repeating: "*", count: 500), "📁 /a/b/c 🎉",
        "[a](b)[c](d)", "`a`b`c`", "- - - -",
    ])
    func hostileInputDoesNotTrap(prose: String) {
        _ = Narration.speakable(prose)
    }
}
