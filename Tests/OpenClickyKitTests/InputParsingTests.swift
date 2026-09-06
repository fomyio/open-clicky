import Testing
import AppKit
import CoreGraphics
import Carbon.HIToolbox
@testable import OpenClickyKit

/// Key-combination parsing, tested without posting events — driving the real
/// injector would type into whatever has focus, including this terminal.
///
/// A wrong keycode fails silently and destructively: `cmd+s` mapped to the wrong
/// key does something else entirely and reports success.
@Suite("Key combination parsing")
struct InputParsingTests {

    private func parse(_ combo: String) throws -> (flags: CGEventFlags, keyCode: CGKeyCode) {
        try InputInjector.parse(combo: combo)
    }

    @Test("A bare key has no modifiers")
    func parsesBareKey() throws {
        let escape = try parse("Escape")
        #expect(escape.keyCode == CGKeyCode(kVK_Escape))
        #expect(escape.flags.isEmpty)

        #expect(try parse("Return").keyCode == CGKeyCode(kVK_Return))
        #expect(try parse("Tab").keyCode == CGKeyCode(kVK_Tab))
    }

    @Test("Key names are case-insensitive", arguments: ["escape", "ESCAPE", "Escape", "eScApE"])
    func keyNamesAreCaseInsensitive(name: String) throws {
        #expect(try parse(name).keyCode == CGKeyCode(kVK_Escape))
    }

    @Test("Each modifier maps to its flag")
    func parsesEachModifier() throws {
        #expect(try parse("cmd+s").flags.contains(.maskCommand))
        #expect(try parse("ctrl+c").flags.contains(.maskControl))
        #expect(try parse("alt+f").flags.contains(.maskAlternate))
        #expect(try parse("shift+a").flags.contains(.maskShift))
        #expect(try parse("fn+F5").flags.contains(.maskSecondaryFn))
    }

    @Test("Modifier aliases are accepted", arguments: [
        ("cmd+s", "command+s"), ("alt+f", "option+f"), ("alt+f", "opt+f"), ("ctrl+c", "control+c"),
    ])
    func acceptsAliases(pair: (String, String)) throws {
        #expect(try parse(pair.0).flags == parse(pair.1).flags)
    }

    @Test("Modifiers combine")
    func combinesModifiers() throws {
        let combo = try parse("cmd+shift+alt+4")
        #expect(combo.flags.contains(.maskCommand))
        #expect(combo.flags.contains(.maskShift))
        #expect(combo.flags.contains(.maskAlternate))
        #expect(!combo.flags.contains(.maskControl))
    }

    /// The last component is the key; everything before it is a modifier. Getting
    /// this backwards would send the modifier as the keystroke.
    @Test("The final component is the key, not a modifier")
    func lastComponentIsTheKey() throws {
        #expect(try parse("cmd+shift+Tab").keyCode == CGKeyCode(kVK_Tab))
        #expect(try parse("ctrl+alt+Delete").keyCode == CGKeyCode(kVK_Delete))
    }

    @Test("Whitespace around components is tolerated")
    func toleratesWhitespace() throws {
        let spaced = try parse("cmd + shift + s")
        let tight = try parse("cmd+shift+s")
        #expect(spaced.keyCode == tight.keyCode)
        #expect(spaced.flags == tight.flags)
    }

    @Test("Arrow and navigation keys resolve", arguments: [
        ("Left", kVK_LeftArrow), ("Right", kVK_RightArrow),
        ("Up", kVK_UpArrow), ("Down", kVK_DownArrow),
        ("Home", kVK_Home), ("End", kVK_End),
        ("PageUp", kVK_PageUp), ("PageDown", kVK_PageDown),
    ])
    func resolvesNavigationKeys(pair: (String, Int)) throws {
        #expect(try parse(pair.0).keyCode == CGKeyCode(pair.1))
    }

    @Test("Function keys resolve", arguments: [("F1", kVK_F1), ("F5", kVK_F5), ("F12", kVK_F12)])
    func resolvesFunctionKeys(pair: (String, Int)) throws {
        #expect(try parse(pair.0).keyCode == CGKeyCode(pair.1))
    }

    @Test("Single characters resolve to their US-layout code")
    func resolvesCharacters() throws {
        #expect(try parse("a").keyCode == 0)
        #expect(try parse("s").keyCode == 1)
        #expect(try parse("z").keyCode == 6)
        // Uppercase resolves to the same physical key; shift is a separate modifier.
        #expect(try parse("A").keyCode == parse("a").keyCode)
    }

    @Test("Common shortcuts parse end to end", arguments: [
        "cmd+s", "cmd+c", "cmd+v", "cmd+z", "cmd+shift+z", "cmd+a", "cmd+f",
        "cmd+shift+4", "ctrl+alt+Delete", "cmd+Tab", "cmd+w", "cmd+q",
    ])
    func parsesCommonShortcuts(combo: String) throws {
        _ = try parse(combo)
    }

    // MARK: - Failure modes

    /// Failing loudly matters: silently dropping an unknown modifier would send the
    /// bare key, so `cmd+q` typed as `qmd+q` would just type "q" into the document.
    @Test("An unknown modifier is rejected rather than ignored", arguments: [
        "hyper+s", "qmd+q", "win+r", "meta2+a",
    ])
    func rejectsUnknownModifiers(combo: String) {
        #expect(throws: InputInjector.Error.self) { try parse(combo) }
    }

    @Test("An unknown key is rejected", arguments: ["Frobnicate", "F99", "ScrollLock", ""])
    func rejectsUnknownKeys(name: String) {
        #expect(throws: InputInjector.Error.self) { try parse(name) }
    }

    @Test("A trailing separator is rejected rather than silently dropped")
    func rejectsTrailingSeparator() {
        // "cmd+" has no key; treating cmd as the key would press the wrong thing.
        #expect(throws: InputInjector.Error.self) { try parse("cmd+") }
    }

    @Test("The error names the offending component")
    func errorNamesTheProblem() {
        do {
            _ = try parse("hyper+s")
            Issue.record("expected a throw")
        } catch let error as InputInjector.Error {
            #expect(error.description.contains("hyper"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

/// Arithmetic that decides how much the screen actually moves. Separated from the
/// CGEvent posting so it can be checked without scrolling anything.
@Suite("Scroll distribution")
struct ScrollStepTests {

    private func delivered(x: Int = 0, y: Int = 0) -> (x: Int, y: Int) {
        InputInjector.scrollSteps(deltaX: x, deltaY: y)
            .reduce(into: (x: 0, y: 0)) { $0.x += $1.x; $0.y += $1.y }
    }

    /// Dividing the total by the step count truncated the remainder, and the loss was
    /// worst where it was least affordable: a request to scroll 11 delivered 6. The
    /// model sees less movement than it asked for and scrolls again, or concludes the
    /// view did not respond.
    @Test("A scroll delivers exactly what was requested", arguments: [
        0, 1, 5, 10, 11, 12, 49, 50, 100, 121, 999,
        -1, -11, -50, -100, -121,
    ])
    func deliversTheFullAmount(delta: Int) {
        #expect(delivered(y: delta).y == delta)
        #expect(delivered(x: delta).x == delta)
    }

    @Test("Both axes are delivered in full together")
    func bothAxesAreExact() {
        let total = delivered(x: 37, y: -83)
        #expect(total.x == 37)
        #expect(total.y == -83)
    }

    /// A large scroll is split so momentum-aware views read it as a gesture; a small
    /// one is a single event, since splitting it would round every step to zero.
    @Test("Large scrolls are split, small ones are not")
    func stepCountMatchesTheDistance() {
        #expect(InputInjector.scrollSteps(deltaX: 0, deltaY: 5).count == 1)
        #expect(InputInjector.scrollSteps(deltaX: 0, deltaY: 10).count == 1)
        #expect(InputInjector.scrollSteps(deltaX: 0, deltaY: 11).count > 1)
        #expect(InputInjector.scrollSteps(deltaX: 200, deltaY: 0).count > 1)
    }

    @Test("Every step moves in the requested direction")
    func stepsDoNotReverse() {
        for step in InputInjector.scrollSteps(deltaX: 0, deltaY: -100) {
            #expect(step.y <= 0, "a downward scroll must not contain an upward step")
        }
        for step in InputInjector.scrollSteps(deltaX: 0, deltaY: 100) {
            #expect(step.y >= 0)
        }
    }

    /// The remainder is spread rather than dumped on one event, so the motion stays
    /// even — a single outsized step reads as a jolt.
    @Test("The remainder is spread across steps, not concentrated")
    func remainderIsSpreadEvenly() {
        let steps = InputInjector.scrollSteps(deltaX: 0, deltaY: 100).map(\.y)
        let smallest = steps.min() ?? 0
        let largest = steps.max() ?? 0
        #expect(largest - smallest <= 1, "steps were \(steps)")
    }

    @Test("A zero scroll produces no movement")
    func zeroIsANoOp() {
        #expect(delivered(x: 0, y: 0) == (x: 0, y: 0))
    }
}


/// How text gets entered. Extracted from the posting so the choice can be checked
/// without typing into whatever has focus — and because nothing verified it: removing
/// the clipboard path entirely left every test passing.
@Suite("Typing strategy")
struct TypingStrategyTests {

    /// Per-character events drop and reorder under load and are slow past a few dozen
    /// characters, so long text goes via the clipboard.
    @Test("Long text is pasted, short text is typed")
    func lengthDecidesTheStrategy() {
        #expect(InputInjector.typingStrategy(for: "hello") == .keystrokes)
        #expect(InputInjector.typingStrategy(for: String(repeating: "a", count: 60)) == .keystrokes)
        #expect(InputInjector.typingStrategy(for: String(repeating: "a", count: 61)) == .clipboard)
    }

    /// A newline sent as Return submits the form rather than entering a line break,
    /// so any multi-line text is pasted however short it is.
    @Test("Multi-line text is always pasted", arguments: [
        "a\nb", "\n", "line one\nline two",
    ])
    func newlinesForceTheClipboard(text: String) {
        #expect(InputInjector.typingStrategy(for: text) == .clipboard)
    }

    @Test("The threshold is honoured when overridden")
    func thresholdIsRespected() {
        #expect(InputInjector.typingStrategy(for: "abcdef", threshold: 3) == .clipboard)
        #expect(InputInjector.typingStrategy(for: "ab", threshold: 3) == .keystrokes)
    }

    @Test("Empty text needs no clipboard round trip")
    func emptyTextIsTyped() {
        #expect(InputInjector.typingStrategy(for: "") == .keystrokes)
    }

    // MARK: - Clipboard preservation

    /// Typing long text pastes it, so the user's clipboard is borrowed and must be
    /// handed back. The restore read the old contents with `string(forType:)`, which
    /// sees only text — a copied image, file or styled snippet came back as nil, the
    /// restore was skipped, and the user was left holding the agent's text. Exactly
    /// the loss the restore exists to prevent, for every clipboard that was not plain
    /// text. Uses a private pasteboard, never the user's.
    @Test("A non-text clipboard survives being borrowed")
    func nonTextClipboardIsRestored() throws {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD])
        let original = NSPasteboardItem()
        original.setData(png, forType: .png)
        original.setString("the alt text", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([original])

        let saved = InputInjector.snapshot(pasteboard)

        // What `paste` does in between: takes the clipboard for itself.
        pasteboard.clearContents()
        pasteboard.setString("text the agent is typing", forType: .string)

        InputInjector.restore(saved, to: pasteboard)

        #expect(pasteboard.data(forType: .png) == png, "the image was destroyed")
        #expect(pasteboard.string(forType: .string) == "the alt text")
    }

    @Test("An empty clipboard is restored as empty, not left holding the agent's text")
    func emptyClipboardIsRestoredEmpty() {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let saved = InputInjector.snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("text the agent is typing", forType: .string)
        InputInjector.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == nil)
    }

    /// The sweep found the previous version of these tests defended nothing: they
    /// exercised snapshot, restore and isUnchanged, while the code that wires them
    /// together lived in `paste`, which drives the real machine and no test can reach.
    /// These drive the seam itself.
    @Test("Borrowing hands the clipboard back as it was")
    func borrowingRestoresTheOriginal() throws {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD])
        let original = NSPasteboardItem()
        original.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([original])

        var sawOurText: String?
        InputInjector.borrowing(pasteboard, placing: "agent text") {
            sawOurText = pasteboard.string(forType: .string)
        }

        #expect(sawOurText == "agent text", "the body should see the text to be pasted")
        #expect(pasteboard.data(forType: .png) == png, "the image was not handed back")
    }

    @Test("Borrowing hands the clipboard back even when the body throws")
    func borrowingRestoresOnThrow() {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what the user had", forType: .string)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try InputInjector.borrowing(pasteboard, placing: "agent text") { throw Boom() }
        }
        #expect(pasteboard.string(forType: .string) == "what the user had")
    }

    /// The wiring the sweep found undefended: the guard is inside `borrowing`, so a
    /// third-party write during the body must survive.
    @Test("Borrowing leaves a clipboard someone else changed alone")
    func borrowingDoesNotClobberAThirdPartyWrite() {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what the user had", forType: .string)

        InputInjector.borrowing(pasteboard, placing: "agent text") {
            // Someone copies while the paste is in flight.
            pasteboard.clearContents()
            pasteboard.setString("what the user just copied", forType: .string)
        }

        #expect(pasteboard.string(forType: .string) == "what the user just copied",
                "the restore overwrote a newer clipboard")
    }

    /// Typing borrows the clipboard for roughly 160ms. Someone who copies during that
    /// window would otherwise have their brand-new clipboard silently overwritten by a
    /// snapshot of what they had before — the agent restoring the user's data over the
    /// top of the user's data, with nothing to show it happened.
    @Test("A clipboard changed by someone else is left alone")
    func aThirdPartyWriteIsNotClobbered() {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("what the user had", forType: .string)
        let saved = InputInjector.snapshot(pasteboard)

        // What paste does: takes the clipboard, then remembers that it is ours.
        pasteboard.clearContents()
        pasteboard.setString("text the agent is typing", forType: .string)
        let ours = pasteboard.changeCount
        #expect(InputInjector.isUnchanged(pasteboard, since: ours))

        // Someone copies something while the paste is in flight.
        pasteboard.clearContents()
        pasteboard.setString("what the user just copied", forType: .string)
        #expect(!InputInjector.isUnchanged(pasteboard, since: ours),
                "a third-party write went unnoticed")

        if InputInjector.isUnchanged(pasteboard, since: ours) {
            InputInjector.restore(saved, to: pasteboard)
        }
        #expect(pasteboard.string(forType: .string) == "what the user just copied",
                "the restore overwrote a newer clipboard")
    }

    @Test("Every type on the clipboard is carried across, not just the first")
    func allTypesAreCarried() {
        let pasteboard = NSPasteboard(name: .init("com.openclicky.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setData(Data("<b>rich</b>".utf8), forType: .html)
        item.setString("file:///tmp/x", forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let saved = InputInjector.snapshot(pasteboard)
        pasteboard.clearContents()
        InputInjector.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "plain")
        #expect(pasteboard.data(forType: .html) == Data("<b>rich</b>".utf8))
        #expect(pasteboard.string(forType: .fileURL) == "file:///tmp/x")
    }

    /// A promised type's data is produced on demand by the owning app, so resolving
    /// one blocks on that process — on the path that types text, with no timeout.
    /// Apple spells these both ways, and matching lowercase caught
    /// `public.file-promise` while needing an exact string for
    /// `com.apple.NSFilePromiseItemMetaData`: any capital-P type nobody had listed
    /// would have been resolved anyway.
    @Test("Promised types are skipped however they are spelled", arguments: [
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.NSFilePromiseReceiver",
        "public.file-promise",
    ])
    func promisedTypesAreSkipped(name: String) {
        #expect(InputInjector.isPromised(NSPasteboard.PasteboardType(name)))
    }

    /// The types actually worth preserving must not be swept up with them.
    @Test("Ordinary types are still resolved", arguments: [
        "public.png", "public.utf8-plain-text", "public.rtf",
        "public.file-url", "com.adobe.pdf",
    ])
    func ordinaryTypesAreResolved(name: String) {
        #expect(!InputInjector.isPromised(NSPasteboard.PasteboardType(name)))
    }
}
