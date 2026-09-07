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

    /// The capture is injected rather than left to default to the real screen.
    ///
    /// Doing nothing does not make the machine hold still: this asserted that the
    /// before and after fingerprints matched while reading the actual frontmost
    /// window, so a menu-bar clock ticking between the two samples reported a change
    /// and failed the test — roughly two runs in six. The subject here is the wording
    /// of the advice, which has nothing to do with the live UI, so the only thing the
    /// real screen contributed was noise.
    @Test("A no-op action tells the model not to retry the same coordinates")
    func noOpActionAdvisesADifferentStrategy() async {
        // A capture that never changes, so "nothing happened" is a fact, not a hope.
        let samples = Samples(changingAfter: .max)
        let outcome = await Verified.act(
            describing: "Clicked (10, 10)", settle: .milliseconds(1),
            capture: { _ in samples.next() }
        ) {}
        #expect(outcome.report.contains("No observable change"))
        #expect(outcome.report.contains("do not repeat the same coordinates"))
        #expect(outcome.report.contains("ax_capture"), "it should name the cheaper, reliable alternative")
    }

    // MARK: - The verdict as a value

    // The prose was the only place the verdict lived, and it stopped at the model.
    // Session `39BAB4C3-478C-4D37-9933-9E2C5E2DDC45`: `key` returned "Pressed
    // cmd+shift+p. No observable change: …", the model wrote "The command palette
    // didn't open.", and the run recorded `act=1 obs=1 unfulfilled=False` and exited
    // 0. These tests pin the finding to the type, so the loop can count it without
    // reading English — the wording above is a UI string and will be reworded.

    @Test("A no-op reports its verdict as a value, not only as prose")
    func noOpOutcomeCarriesItsVerdict() async {
        let samples = Samples(changingAfter: .max)
        let outcome = await Verified.act(
            describing: "Pressed cmd+shift+p", settle: .milliseconds(1),
            capture: { _ in samples.next() }
        ) {}
        #expect(outcome.observedChange == false)
    }

    @Test("A real change reports its verdict as a value too")
    func changedOutcomeCarriesItsVerdict() async {
        let samples = Samples(changingAfter: 2)
        let outcome = await Verified.act(
            describing: "Clicked", settle: .milliseconds(1000),
            capture: { _ in samples.next() }
        ) {}
        #expect(outcome.observedChange)
        #expect(outcome.report.hasPrefix("Clicked"))
    }

    /// The two fixes composing. Suppressed self-noise is reported in words as "was
    /// ignored", and the verdict underneath has to agree: the agent's own terminal
    /// printing a line is not evidence that a keystroke landed, in prose *or* in the
    /// arithmetic. The measured session is exactly this shape.
    @Test("Suppressed self-noise is not evidence of change in the verdict either")
    func selfNoiseOnlyIsNotAChangedVerdict() async {
        let outcome = await Verified.act(
            describing: "Pressed cmd+shift+p",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(1),
            capture: Phases(terminal(value: "(base) mosaab@19"),
                            then: terminal(value: "Last login: Wed Sep  2 15:12:22")).next
        ) {}
        #expect(outcome.observedChange == false, "self-noise counted as evidence: \(outcome)")
        #expect(outcome.report.contains("was ignored"))
    }

    /// The seam between the two layers: a verdict that never reaches `ToolOutput` is
    /// a verdict the loop cannot count, which is the whole defect.
    @Test("A verified outcome becomes a tool output that still carries the verdict")
    func verifiedOutcomeReachesToolOutput() {
        let missed = ToolOutput.verified(
            Verified.Outcome(report: "Pressed cmd+shift+p. No observable change: …",
                             observedChange: false)
        )
        #expect(missed.changeVerdict == .unchanged)
        #expect(!missed.isError, "a miss is a successful call that changed nothing")

        let landed = ToolOutput.verified(
            Verified.Outcome(report: "Clicked (10, 10). Frontmost app is now Code.",
                             observedChange: true)
        )
        #expect(landed.changeVerdict == .changed)
    }

    /// The guard against the tempting `Bool`. Every tool that does not verify itself
    /// must be distinguishable from one that verified and found nothing — collapsing
    /// the two would stop `write_file` and `shell` from ever counting as actions.
    @Test("A tool output that was never verified says so, and says it by default")
    func unverifiedIsTheDefaultAndItsOwnState() {
        #expect(ToolOutput.text("954 Code").changeVerdict == .unverified)
        #expect(ToolOutput.failure("boom").changeVerdict == .unverified)
        #expect(ToolOutput.image(mediaType: "image/jpeg", base64: "x").changeVerdict == .unverified)
        #expect(ToolOutput(content: [.text("ok")]).changeVerdict == .unverified)
        #expect(ChangeVerdict.unverified != ChangeVerdict.unchanged)
    }

    @Test("The description always leads the report")
    func descriptionLeadsTheReport() async {
        let outcome = await Verified.act(describing: "Pressed cmd+s", settle: .milliseconds(1)) {}
        #expect(outcome.report.hasPrefix("Pressed cmd+s"))
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
            describing: "Clicked", settle: .milliseconds(1000), capture: { _ in samples.next() }
        ) {}
        let elapsed = ContinuousClock.now - start

        #expect(!outcome.report.contains("No observable change"))
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
            describing: "Clicked", settle: .milliseconds(200), capture: { _ in samples.next() }
        ) {}
        let elapsed = ContinuousClock.now - start

        #expect(outcome.report.contains("No observable change"))
        #expect(elapsed >= .milliseconds(150), "gave up after \(elapsed)")
    }

    @Test("Polling samples repeatedly rather than once")
    func pollsMoreThanOnce() async {
        let samples = Samples(changingAfter: .max)
        _ = await Verified.act(
            describing: "Clicked", settle: .milliseconds(200), capture: { _ in samples.next() }
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
        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1
        ))

        struct SilentPointer: PointerActing {
            func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {}
            func drag(from start: CGPoint, to end: CGPoint) throws {}
            func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {}
        }

        let output = try await ClickTool(pointer: SilentPointer(), context: context).run(
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

    /// Same gap as `click`: the wrapper existing and `type` using it are separate
    /// facts, and removing the call left every test passing.
    @Test("Typing reports what changed")
    func typeReportsVerification() async throws {
        let output = try await TypeTool().run(.object(["text": .string("")]))
        let report = output.content.compactMap {
            if case let .text(text) = $0 { return text } else { return nil }
        }.joined()
        // Empty text is a no-op, so the report must be a verification result rather
        // than an unconditional claim of success.
        #expect(report.contains("No observable change") || report.contains("focus")
                    || report.contains("frontmost") || report.contains("window"),
                "type reported '\(report)' with no verification")
    }

    /// Every mutating tool, asserted as a set rather than one at a time.
    ///
    /// Three separate mutations found `click`, `type` and `key` unverified, each
    /// needing its own test — and writing this one immediately found two more that
    /// had never verified at all: `scroll` and `ax_set_value`. A tool added later is
    /// covered without anyone remembering to add it.
    @Test("Every action reports what changed rather than that it ran")
    func everyActionIsVerified() async throws {
        struct SilentPointer: PointerActing {
            func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {}
            func drag(from start: CGPoint, to end: CGPoint) throws {}
            func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {}
        }

        let context = ScreenContext()
        await context.record(Screenshot(
            jpegBase64: "", imageSize: CGSize(width: 100, height: 100),
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1
        ))

        let cases: [(name: String, tool: any Tool, arguments: JSONValue)] = [
            ("click", ClickTool(pointer: SilentPointer(), context: context),
             .object(["x": .number(10), "y": .number(10)])),
            ("drag", DragTool(pointer: SilentPointer(), context: context),
             .object(["from_x": .number(1), "from_y": .number(1),
                      "to_x": .number(9), "to_y": .number(9)])),
            ("scroll", ScrollTool(pointer: SilentPointer(), context: context),
             .object(["x": .number(10), "y": .number(10), "delta_y": .number(-20)])),
            ("type", TypeTool(), .object(["text": .string("")])),
        ]

        for (name, tool, arguments) in cases {
            let output = try await tool.run(arguments)
            let report = output.content.compactMap {
                if case let .text(text) = $0 { return text } else { return nil }
            }.joined()

            // Either it names what changed, or it says nothing did — both are
            // verification. What it must not do is assert success unconditionally.
            let verified = report.contains("No observable change")
                || report.contains("frontmost") || report.contains("focus")
                || report.contains("window") || report.contains("value changed")
            #expect(verified, "\(name) reported '\(report)' without verifying")
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

    /// A scroll changes no app, no window and no focused element, so the fingerprint
    /// could not see one at all: every scroll — the ones that worked included —
    /// reported "no observable change", which tells the model the action missed and
    /// to try something else. The one action whose whole purpose is to move content
    /// was the one action verification was blind to.
    @Test("A scroll is an observable change")
    func scrollIsObservable() {
        func fingerprint(at offset: Double) -> UIFingerprint {
            UIFingerprint(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit",
                          windowTitle: "notes.txt", focusedRole: "AXTextArea",
                          focusedTitle: nil, focusedValue: nil, scrollPositions: [offset])
        }

        let moved = fingerprint(at: 0.42).changes(since: fingerprint(at: 0.10))
        #expect(moved?.contains("scrolled down") == true, "got \(moved ?? "nil")")
        #expect(moved?.contains("42%") == true)

        let back = fingerprint(at: 0.10).changes(since: fingerprint(at: 0.42))
        #expect(back?.contains("scrolled up") == true)

        #expect(fingerprint(at: 0.42).changes(since: fingerprint(at: 0.42)) == nil,
                "an unchanged offset must not read as movement")
    }

    /// A scroll view settling a fraction of a pixel on its own is not a scroll.
    @Test("Sub-threshold drift is not reported as scrolling")
    func scrollToleranceIgnoresDrift() {
        func fingerprint(at offset: Double) -> UIFingerprint {
            UIFingerprint(bundleIdentifier: "a", appName: "A", windowTitle: nil,
                          focusedRole: nil, focusedTitle: nil, focusedValue: nil,
                          scrollPositions: [offset])
        }
        #expect(fingerprint(at: 0.500_02).changes(since: fingerprint(at: 0.5)) == nil)
        #expect(fingerprint(at: 0.502).changes(since: fingerprint(at: 0.5)) != nil)
    }

    /// The scroll walk is 60x the cost of the rest of the fingerprint, so it must not
    /// be on the polling path — polling with it spent the entire settle budget on IPC
    /// instead of watching for the change it was waiting for.
    @Test("Polling never pays for the scroll walk")
    func scrollWalkIsNotOnThePollingPath() async throws {
        let requests = Requests()
        let unchanging = UIFingerprint(
            bundleIdentifier: "a", appName: "A", windowTitle: nil, focusedRole: nil,
            focusedTitle: nil, focusedValue: nil, scrollPositions: [0.5]
        )
        _ = await Verified.act(
            describing: "Clicked", settle: .milliseconds(120),
            capture: { includingScroll in
                requests.record(includingScroll)
                return unchanging
            }
        ) { }

        let all = requests.all
        #expect(all.count > 3, "it should have polled repeatedly")
        #expect(all.first == true, "the baseline must carry scroll offsets")
        #expect(all.last == true, "the final comparison must carry scroll offsets")
        #expect(all.dropFirst().dropLast().allSatisfy { $0 == false },
                "a poll asked for the expensive walk")
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []
        func record(_ value: Bool) { lock.lock(); storage.append(value); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Reading only the first scroll area found reintroduced the false negative the
    /// field exists to remove, in exactly the apps most likely to be driven. In Mail,
    /// Xcode, Finder or any split view the sidebar is a plausible first hit, and it
    /// does not move when the content pane scrolls — so a successful scroll reported
    /// "no observable change", which tells the model the action missed.
    @Test("A content pane scrolling is seen even when the sidebar does not move")
    func scrollInAnyPaneIsObserved() {
        func window(sidebar: Double, content: Double) -> UIFingerprint {
            UIFingerprint(bundleIdentifier: "com.apple.mail", appName: "Mail",
                          windowTitle: "Inbox", focusedRole: "AXTextArea",
                          focusedTitle: nil, focusedValue: nil,
                          scrollPositions: [sidebar, content])
        }

        let scrolled = window(sidebar: 0.0, content: 0.6)
            .changes(since: window(sidebar: 0.0, content: 0.1))
        #expect(scrolled?.contains("scrolled down") == true, "got \(scrolled ?? "nil")")

        // And the sidebar moving on its own is equally real.
        let sidebarMoved = window(sidebar: 0.3, content: 0.1)
            .changes(since: window(sidebar: 0.0, content: 0.1))
        #expect(sidebarMoved?.contains("scrolled down") == true)

        #expect(window(sidebar: 0.2, content: 0.6)
            .changes(since: window(sidebar: 0.2, content: 0.6)) == nil)
    }

    /// The walk is bounded, so it can return a different number of areas either side
    /// of an action. Lining up unrelated panes by position would turn a structural
    /// change into a fabricated scroll — a false positive replacing a false negative.
    @Test("Panes are only compared when the same number were found")
    func mismatchedPaneCountsAreNotScrolling() {
        func window(_ offsets: [Double]) -> UIFingerprint {
            UIFingerprint(bundleIdentifier: "a", appName: "A", windowTitle: nil,
                          focusedRole: nil, focusedTitle: nil, focusedValue: nil,
                          scrollPositions: offsets)
        }
        #expect(window([0.5, 0.1]).changes(since: window([0.5])) == nil)
        #expect(window([]).changes(since: window([0.5])) == nil)
    }

    /// An app with nothing scrollable must not make every action look like a scroll.
    @Test("A window with no scroll area reports no scrolling")
    func absentScrollPositionIsNotAChange() {
        let a = UIFingerprint(bundleIdentifier: "a", appName: "A", windowTitle: nil,
                              focusedRole: nil, focusedTitle: nil, focusedValue: nil,
                              scrollPositions: [])
        #expect(a.changes(since: a) == nil)
    }

    // MARK: - The agent's own surfaces

    /// A change has to say where it happened.
    ///
    /// "the focused element's value changed to …" reads as success wherever it
    /// happened — and in the run that motivated this it happened in the terminal
    /// running the agent, not in the app the keystroke was aimed at.
    @Test("A value change names the app it happened in")
    func valueChangeNamesItsApp() {
        let before = fingerprint(role: "AXTextArea", title: nil, value: "one")
        let after = fingerprint(role: "AXTextArea", title: nil, value: "two")
        let changes = try! #require(after.changes(since: before))
        #expect(changes.contains("Safari"), "got \(changes)")
    }

    @Test("A focus move names the app it happened in")
    func focusChangeNamesItsApp() {
        let after = fingerprint(role: "AXTextField", title: "Name")
        let changes = try! #require(after.changes(since: fingerprint()))
        #expect(changes.contains("Safari"), "got \(changes)")
    }

    /// The regression this exists for. `UIFingerprint` samples the frontmost app, and
    /// for a CLI that is the terminal it is printing into — whose focused element's
    /// value is the agent's own scrollback. Measured: over five samples two seconds
    /// apart with no action at all, the title changed 0/4 intervals and the value 4/4.
    /// So every action reported a change, and "No observable change" was unreachable.
    /// A `cmd+shift+p` meant for VS Code came back confirmed by "Last login: …".
    @Test("A value change in the agent's own terminal is not evidence")
    func selfValueChangeIsNotEvidence() async {
        let outcome = await Verified.act(
            describing: "Pressed cmd+shift+p",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(1),
            capture: Phases(terminal(value: "(base) mosaab@19"),
                            then: terminal(value: "Last login: Wed Sep  2 15:12:22")).next
        ) {}
        #expect(outcome.report.contains("No observable change"))
        #expect(outcome.report.contains("was ignored"),
                "silent suppression would be a second invisible mechanism: \(outcome)")
        #expect(outcome.report.contains("Terminal"))
    }

    /// Only the agent's own surfaces are discounted. A field whose value changed in
    /// the app actually being driven is the most common Tier 3 success there is.
    @Test("A value change in another app is still evidence")
    func otherAppValueChangeSurvives() async {
        let outcome = await Verified.act(
            describing: "Typed 6 characters",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(200),
            capture: Phases(fingerprint(role: "AXTextField", title: "Name", value: ""),
                            then: fingerprint(role: "AXTextField", title: "Name", value: "Yassir")).next
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("Yassir"))
    }

    /// Suppression is the value field and nothing else. A window title does not churn
    /// on its own — 0/4 intervals, measured — so it is real evidence even here.
    @Test("A window title change in a self app is a real change")
    func selfWindowTitleChangeIsEvidence() async {
        let outcome = await Verified.act(
            describing: "Pressed cmd+n",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(200),
            capture: Phases(terminal(window: "zsh — 80x24", value: "a"),
                            then: terminal(window: "bash — 120x40", value: "b")).next
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("bash — 120x40"))
    }

    /// The action that worked and switched away: the frontmost app moving is the
    /// clearest evidence there is, and must not be swallowed by the app it left.
    @Test("Leaving a self app is a real change")
    func frontmostAppChangeFromSelfIsEvidence() async {
        let outcome = await Verified.act(
            describing: "Pressed cmd+tab",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(200),
            capture: Phases(terminal(value: "a"), then: fingerprint(value: "x")).next
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("Safari"))
    }

    /// Guards the false negative `scrollPositions` was added to fix from being
    /// re-broken by this one: a scroll in the agent's own window still moved something.
    @Test("A scroll in a self app is a real change")
    func selfScrollIsEvidence() async {
        let outcome = await Verified.act(
            describing: "Scrolled -300px",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(200),
            capture: Phases(terminal(value: "a", scroll: [0.2]),
                            then: terminal(value: "b", scroll: [0.9])).next
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("scrolled down"))
    }

    /// The default. Nothing about verification changes for a caller that never names
    /// a surface of its own — which is every test above this line.
    @Test("An empty self set suppresses nothing")
    func emptySelfSetChangesNothing() async {
        let outcome = await Verified.act(
            describing: "Pressed cmd+shift+p", settle: .milliseconds(200),
            capture: Phases(terminal(value: "before"), then: terminal(value: "after")).next
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("after"))
    }

    /// Polling has to apply the same rule as the verdict. Asking only at the end would
    /// break out of the loop on the first frame the terminal printed a line — which is
    /// immediately — and then discount it, so an app that answers in 200ms would be
    /// reported as a miss.
    @Test("Polling waits through self noise for real evidence")
    func pollingIgnoresSelfNoise() async {
        let samples = SelfNoiseThenRealChange()
        let outcome = await Verified.act(
            describing: "Pressed cmd+shift+p",
            selfBundleIDs: ["com.apple.Terminal"], settle: .milliseconds(500),
            capture: { _ in samples.next() }
        ) {}
        #expect(!outcome.report.contains("No observable change"), "got \(outcome)")
        #expect(outcome.report.contains("Code"), "it should have waited for the real app: \(outcome)")
    }

    /// Emits the host terminal churning its own scrollback, then the app being driven
    /// coming forward — the shape of a slow app answering a keystroke.
    private final class SelfNoiseThenRealChange: @unchecked Sendable {
        static let baseline = UIFingerprint(
            bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
            windowTitle: "zsh", focusedRole: "AXTextArea", focusedTitle: nil,
            focusedValue: "line 0"
        )
        private let lock = NSLock()
        private var calls = 0

        func next() -> UIFingerprint {
            lock.lock()
            calls += 1
            let count = calls
            lock.unlock()
            // The first sample is the baseline `Verified.act` compares everything to.
            guard count > 1 else { return Self.baseline }
            guard count > 4 else {
                return UIFingerprint(
                    bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
                    windowTitle: "zsh", focusedRole: "AXTextArea", focusedTitle: nil,
                    focusedValue: "line \(count)"
                )
            }
            return UIFingerprint(
                bundleIdentifier: "com.microsoft.VSCode", appName: "Code",
                windowTitle: "main.swift", focusedRole: "AXTextArea",
                focusedTitle: nil, focusedValue: "line \(count)"
            )
        }
    }

    /// `Verified.act` takes its baseline from the first sample, so a test needing
    /// before ≠ after answers the first call with one fingerprint and every later
    /// call with another. Nothing here reads the real machine: the frontmost app on
    /// the test runner is not the subject.
    private final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        private let before: UIFingerprint
        private let after: UIFingerprint

        init(_ before: UIFingerprint, then after: UIFingerprint) {
            self.before = before
            self.after = after
        }

        var next: @Sendable (Bool) -> UIFingerprint {
            { [self] _ in
                lock.lock()
                defer { taken = true; lock.unlock() }
                return taken ? after : before
            }
        }
    }

    private func terminal(
        window: String? = "zsh — 80x24", value: String?, scroll: [Double] = []
    ) -> UIFingerprint {
        UIFingerprint(
            bundleIdentifier: "com.apple.Terminal", appName: "Terminal",
            windowTitle: window, focusedRole: "AXTextArea", focusedTitle: nil,
            focusedValue: value, scrollPositions: scroll
        )
    }
}

/// `TERM_PROGRAM` is how a CLI learns which terminal it is printing into, and that
/// terminal is the surface whose text must not be read as evidence.
@Suite("Host terminal identification")
struct HostTerminalTests {

    @Test("Known terminals map to their bundle identifiers", arguments: [
        ("Apple_Terminal", "com.apple.Terminal"),
        ("iTerm.app", "com.googlecode.iterm2"),
        ("vscode", "com.microsoft.VSCode"),
        ("ghostty", "com.mitchellh.ghostty"),
        ("WarpTerminal", "dev.warp.Warp-Stable"),
        ("kitty", "net.kovidgoyal.kitty"),
    ])
    func mapsKnownTerminals(pair: (String, String)) {
        #expect(HostTerminal.bundleIdentifier(termProgram: pair.0) == pair.1)
    }

    /// Degrading to "no id" is the safe direction: no id means no suppression, which
    /// is the behaviour that existed before any of this. A guessed id would suppress
    /// evidence from an app the agent was genuinely asked to drive.
    @Test("An unset, empty or unknown TERM_PROGRAM yields no identifier")
    func unknownTerminalsYieldNothing() {
        #expect(HostTerminal.bundleIdentifier(termProgram: nil) == nil)
        #expect(HostTerminal.bundleIdentifier(termProgram: "") == nil)
        #expect(HostTerminal.bundleIdentifier(termProgram: "SomeNewTerminal") == nil)
        // Exact match only: a substring must not be enough to claim an app.
        #expect(HostTerminal.bundleIdentifier(termProgram: "vscode-insiders") == nil)
        #expect(HostTerminal.bundleIdentifier(termProgram: "apple_terminal") == nil)
    }

    @Test("The current process reads TERM_PROGRAM, and an absent one is empty")
    func currentReadsTheEnvironment() {
        #expect(HostTerminal.current(environment: ["TERM_PROGRAM": "iTerm.app"])
                == ["com.googlecode.iterm2"])
        #expect(HostTerminal.current(environment: [:]).isEmpty)
        #expect(HostTerminal.current(environment: ["TERM_PROGRAM": "nope"]).isEmpty)
    }
}
