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

    /// The wait exists because a fingerprint taken before the window redraws reports
    /// every action as a no-op. A fixed sleep made every action pay the worst case —
    /// a batch of ten clicks was over a second of pure waiting.
    @Test("A visible change is detected without waiting out the full budget")
    func returnsAsSoonAsTheUIResponds() async {
        let samples = Samples(changingAfter: 2)
        let start = ContinuousClock.now
        let outcome = await Verified.act(
            describing: "Clicked", settle: .milliseconds(1000), capture: samples.next
        ) {}
        let elapsed = ContinuousClock.now - start

        #expect(!outcome.contains("No observable change"))
        #expect(elapsed < .milliseconds(300), "should not have waited out 1000ms; took \(elapsed)")
    }

    /// The two failure modes are not symmetric: a premature "nothing changed" tells
    /// the model to abandon a strategy that actually worked, so the budget is spent
    /// in full before concluding an action missed.
    @Test("A genuine no-op waits out the budget before reporting")
    func waitsBeforeDeclaringNoChange() async {
        let samples = Samples(changingAfter: .max)
        let start = ContinuousClock.now
        let outcome = await Verified.act(
            describing: "Clicked", settle: .milliseconds(200), capture: samples.next
        ) {}
        let elapsed = ContinuousClock.now - start

        #expect(outcome.contains("No observable change"))
        #expect(elapsed >= .milliseconds(150), "gave up after \(elapsed)")
    }

    @Test("Polling samples repeatedly rather than once")
    func pollsMoreThanOnce() async {
        let samples = Samples(changingAfter: .max)
        _ = await Verified.act(
            describing: "Clicked", settle: .milliseconds(200), capture: samples.next
        ) {}
        #expect(samples.count > 3, "only \(samples.count) samples in 200ms")
    }

    /// Emits a fixed fingerprint until the nth call, then a different one.
    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let threshold: Int

        init(changingAfter threshold: Int) { self.threshold = threshold }

        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }

        var next: @Sendable () -> UIFingerprint {
            { [self] in
                lock.lock()
                calls += 1
                let changed = calls > threshold
                lock.unlock()
                return UIFingerprint(
                    bundleIdentifier: "com.example.app", appName: "Example",
                    windowTitle: changed ? "After" : "Before",
                    focusedRole: "AXButton", focusedTitle: "Save", focusedValue: nil
                )
            }
        }
    }

    /// The wrapper existing and the tools using it are separate facts. Found by
    /// mutation: `click` could drop verification entirely and nothing objected.
    @Test("A click reports what changed, not merely that it happened")
    func clickReportsVerification() async throws {
        await ScreenContext.shared.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1
        ))

        struct SilentPointer: PointerActing {
            func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {}
            func drag(from start: CGPoint, to end: CGPoint) throws {}
            func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {}
        }

        let output = try await ClickTool(pointer: SilentPointer()).run(
            .object(["x": .number(10), "y": .number(10)])
        )
        let report = output.content.compactMap {
            if case let .text(text) = $0 { return text } else { return nil }
        }.joined()

        // Nothing on screen changed, so the report must say so — and say what to do
        // about it, rather than implying the click succeeded.
        #expect(report.contains("No observable change") || report.contains("focus")
                    || report.contains("frontmost"),
                "a click reported '\(report)' with no verification")
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
