import Testing
import Foundation
@testable import OpenClickyKit

/// Act-then-verify is the biggest reliability lever for a coordinate-driven agent,
/// because the failure it catches is invisible otherwise: a click that lands on
/// nothing produces exactly the same tool result as one that worked.
@Suite("Post-action verification", .serialized)
struct VerificationTests {

    private func fingerprint(
        bundle: String? = "com.apple.Safari",
        app: String = "Safari",
        window: String? = "Example",
        role: String? = "AXButton",
        title: String? = "Save",
        value: String? = nil
    ) -> UIFingerprint {
        UIFingerprint(
            bundleIdentifier: bundle, appName: app, windowTitle: window,
            focusedRole: role, focusedTitle: title, focusedValue: value
        )
    }

    /// The case that matters: nothing changed, so the model must be told to try a
    /// different approach rather than repeat the same coordinates.
    @Test("An identical fingerprint reports no change")
    func detectsNoChange() {
        let before = fingerprint()
        #expect(before.changes(since: before) == nil)
    }

    @Test("A change of frontmost app is reported")
    func detectsAppChange() {
        let after = fingerprint(bundle: "com.apple.finder", app: "Finder")
        let changes = try! #require(after.changes(since: fingerprint()))
        #expect(changes.contains("Finder"))
    }

    @Test("A change of window is reported")
    func detectsWindowChange() {
        let after = fingerprint(window: "Preferences")
        let changes = try! #require(after.changes(since: fingerprint()))
        #expect(changes.contains("Preferences"))
    }

    @Test("A change of focused element is reported with its role and label")
    func detectsFocusChange() {
        let after = fingerprint(role: "AXTextField", title: "Name")
        let changes = try! #require(after.changes(since: fingerprint()))
        #expect(changes.contains("TextField"))
        #expect(changes.contains("Name"))
        #expect(!changes.contains("AXTextField"), "the AX prefix is noise for the model")
    }

    /// Typing into a field changes its value while role, title and window all stay
    /// put — without this the most common Tier 3 action would report as a no-op.
    @Test("A value change alone is still a change")
    func detectsValueChange() {
        let before = fingerprint(role: "AXTextField", title: "Name", value: "")
        let after = fingerprint(role: "AXTextField", title: "Name", value: "Yassir")
        let changes = try! #require(after.changes(since: before))
        #expect(changes.contains("Yassir"))
    }

    @Test("Several simultaneous changes are all reported")
    func reportsMultipleChanges() {
        let after = fingerprint(bundle: "com.apple.finder", app: "Finder", window: "Downloads")
        let changes = try! #require(after.changes(since: fingerprint()))
        #expect(changes.contains("Finder"))
        #expect(changes.contains("Downloads"))
    }

    @Test("Long values are truncated so verification stays cheap")
    func truncatesLongValues() {
        let before = fingerprint(role: "AXTextArea", title: "Body", value: "short")
        let after = fingerprint(
            role: "AXTextArea", title: "Body", value: String(repeating: "x", count: 500)
        )
        let changes = try! #require(after.changes(since: before))
        #expect(changes.count < 200)
    }

    // MARK: - The verified action wrapper

    @Test("A no-op action tells the model not to retry the same coordinates")
    func noOpActionAdvisesADifferentStrategy() async {
        // Nothing is done, so the before and after fingerprints match.
        let outcome = await Verified.act(describing: "Clicked (10, 10)", settle: .milliseconds(1)) {}
        #expect(outcome.contains("No observable change"))
        #expect(outcome.contains("do not repeat the same coordinates"))
        #expect(outcome.contains("ax_capture"), "it should name the cheaper, reliable alternative")
    }

    @Test("The description always leads the report")
    func descriptionLeadsTheReport() async {
        let outcome = await Verified.act(describing: "Pressed cmd+s", settle: .milliseconds(1)) {}
        #expect(outcome.hasPrefix("Pressed cmd+s"))
    }

    @Test("An action that throws propagates rather than reporting success")
    func propagatesFailures() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await Verified.act(describing: "Clicked", settle: .milliseconds(1)) {
                throw Boom()
            }
        }
    }

    /// Fingerprinting must stay cheap enough to run after every action; a full
    /// accessibility capture after each click would cost more than the click saved.
    @Test("Capturing a fingerprint is fast")
    func fingerprintIsCheap() {
        let start = ContinuousClock.now
        for _ in 0..<5 { _ = UIFingerprint.capture() }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(3), "five fingerprints took \(elapsed)")
    }

    @Test("A fingerprint of the live machine is well-formed")
    func capturesLiveState() {
        let print = UIFingerprint.capture()
        #expect(!print.appName.isEmpty)
        // Under a test runner the focused element may be nothing; the contract is
        // only that capture never crashes and always names an app.
        #expect(print.changes(since: print) == nil)
    }
}
