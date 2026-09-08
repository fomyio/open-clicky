import Foundation
import AppKit
import ApplicationServices

/// A cheap snapshot of "what has focus right now".
///
/// Taken either side of an action so a tool can report whether anything actually
/// changed. Act-then-verify is the single biggest reliability lever for a
/// coordinate-driven agent, and the failure it catches is the common one: a click
/// that lands on nothing looks exactly like a click that worked, so the model
/// proceeds on the assumption that a dialog opened when it did not.
///
/// Deliberately small — a handful of accessibility reads and around fifty tokens.
/// A full `ax_capture` after every click would cost more than the click saved.
/// Two costs, deliberately separated. The cheap fingerprint is five attribute reads
/// at ~0.25ms and is what polling uses. Adding the scroll offsets walks the window's
/// tree, which is 14ms in the worst case measured — an app with no scroll area near
/// the top, so the walk runs to its full budget — and is taken exactly twice per
/// action rather than on every poll.
public struct UIFingerprint: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitle: String?
    public let focusedRole: String?
    public let focusedTitle: String?
    public let focusedValue: String?
    /// Where each scrollable view in the window sits, 0...1, in discovery order.
    ///
    /// Without this a scroll was invisible to verification: the frontmost app, window
    /// and focused element are all identical before and after one, so every scroll —
    /// the ones that worked included — reported "no observable change" and told the
    /// model to abandon a strategy that may have been fine.
    ///
    /// Every scroll area rather than the first one found. A sidebar is a plausible
    /// first hit in Mail, Xcode, Finder or any other split view, and reading only that
    /// would report "nothing moved" for a scroll of the content pane — reintroducing
    /// the exact false negative this field exists to remove, in the apps most likely
    /// to be driven.
    public let scrollPositions: [Double]

    public init(bundleIdentifier: String?, appName: String, windowTitle: String?,
                focusedRole: String?, focusedTitle: String?, focusedValue: String?,
                scrollPositions: [Double] = []) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedTitle = focusedTitle
        self.focusedValue = focusedValue
        self.scrollPositions = scrollPositions
    }

    /// The cheap fingerprint: five attribute reads, no tree walk. What polling uses.
    public static func capture() -> UIFingerprint { capture(includingScroll: false) }

    /// Adds the scroll offsets, which cost a bounded walk of the window's tree — far
    /// more than the rest of the fingerprint put together. Taken twice per action
    /// rather than on every poll: a scroll cannot be detected early anyway, since
    /// nothing else about the window changes when one happens.
    public static func captureIncludingScroll() -> UIFingerprint { capture(includingScroll: true) }

    private static func capture(includingScroll: Bool) -> UIFingerprint {
        let app = NSWorkspace.shared.frontmostApplication
        var windowTitle: String?
        var role: String?
        var title: String?
        var value: String?
        var scrollPositions: [Double] = []

        if AXIsProcessTrusted(), let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            // A hung app must not stall the action loop.
            AXUIElementSetMessagingTimeout(axApp, 1.0)

            let window = copy(axApp, kAXFocusedWindowAttribute)
            windowTitle = string(of: window, kAXTitleAttribute)
            if includingScroll { scrollPositions = scrollOffsets(in: window) }
            if let focused = copy(axApp, kAXFocusedUIElementAttribute) {
                role = string(of: focused, kAXRoleAttribute)
                title = string(of: focused, kAXTitleAttribute)
                let subrole = string(of: focused, kAXSubroleAttribute)
                // Never read a password field's contents. AppKit's own secure fields
                // mask their AX value, but web and custom controls do not always, and
                // this value would otherwise reach the model and the transcript.
                value = reportableValue(
                    role: role, subrole: subrole, label: title,
                    value: string(of: focused, kAXValueAttribute)
                )
            }
        }

        return UIFingerprint(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName ?? "unknown",
            windowTitle: windowTitle,
            focusedRole: role,
            focusedTitle: title,
            focusedValue: value,
            scrollPositions: scrollPositions
        )
    }

    /// What changed between two fingerprints, phrased for the model.
    ///
    /// Returns `nil` when nothing observable changed — which the caller should
    /// report, because "nothing happened" is the signal that an action missed.
    public func changes(since previous: UIFingerprint) -> String? {
        var notes: [String] = []

        if previous.bundleIdentifier != bundleIdentifier {
            notes.append("frontmost app is now \(appName)")
        }
        if previous.windowTitle != windowTitle {
            notes.append("focused window is now \(windowTitle.map { "\"\($0)\"" } ?? "untitled")")
        }
        // Both focus notes name the app they happened in. A change reported as "the
        // focused element's value changed to ..." reads as success wherever it
        // happened, and the run that motivated this was exactly that: a `cmd+shift+p`
        // aimed at VS Code was confirmed by Terminal's scrollback, and neither the
        // model nor the transcript could tell. Four words, and the wrong app is visible.
        if previous.focusedRole != focusedRole || previous.focusedTitle != focusedTitle {
            notes.append("focus is now on \(describeFocus()) in \(appName)")
        } else if previous.focusedValue != focusedValue {
            notes.append("the focused element's value in \(appName) changed to \(focusedValue.map { "\"\($0.truncated(60))\"" } ?? "empty")")
        }

        if let moved = scrollMovement(since: previous) {
            let direction = moved.1 > moved.0 ? "down" : "up"
            notes.append("scrolled \(direction) to \(Int((moved.1 * 100).rounded()))%")
        }

        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// The first scroll offset that moved, as (before, after), or nil if none did.
    ///
    /// Any pane that moved counts. Comparing only when the counts match: a window
    /// that gained or lost a scroll area changed structurally, and calling that
    /// "scrolled" would be a false positive in place of the false negative.
    ///
    /// The tolerance is because a scroll view can settle a fraction of a pixel on
    /// its own; anything a scroll actually moved is orders of magnitude larger.
    ///
    /// Factored out of `changes(since:)` so `isSelfNoise` asks the same question with
    /// the same tolerance. Two copies of this comparison is one copy that can be
    /// weakened alone, and the weaker one would silently re-introduce the false
    /// negative `scrollPositions` exists to remove.
    private func scrollMovement(since previous: UIFingerprint) -> (Double, Double)? {
        guard previous.scrollPositions.count == scrollPositions.count else { return nil }
        return zip(previous.scrollPositions, scrollPositions)
            .first(where: { abs($0 - $1) > 0.0001 })
    }

    /// Whether the only difference since `previous` is one of the agent's own surfaces
    /// redrawing its own text — which is not evidence that anything happened.
    ///
    /// `focusedValue` is the one field of a fingerprint that changes with no action at
    /// all when the frontmost app is the terminal the CLI is running in: the agent's
    /// own progress output is that element's value. Measured on this machine, sampling
    /// Terminal's focused element five times over two seconds with no action taken:
    /// **title changed 0/4 intervals, value changed 4/4**. So `changes(since:)`
    /// returned non-nil every single time through its value branch, and the "no
    /// observable change" advice — the whole point of act-then-verify — became
    /// unreachable. In session `0C2AA9EC…` a `key` press of `cmd+shift+p` intended for
    /// VS Code was reported as `✓ … the focused element's value changed to "Last login:
    /// Wed Sep  2 …"`. VS Code never received the chord; the model built three more
    /// turns on that.
    ///
    /// Only the value is discounted, and only when nothing else moved. The frontmost
    /// app, the window title, the focused role and title, and the scroll offsets do
    /// not churn on their own (0/4 intervals, measured), so a change in any of them is
    /// real evidence even in the agent's own window.
    ///
    /// **The deliberate trade-off:** this makes `type` into the agent's *own* host
    /// terminal report a false negative. That is the correct direction. `Verified.act`
    /// argues the asymmetry the other way for the settle budget — a premature "nothing
    /// changed" costs a working strategy — but the two errors are not the same size
    /// here: a false positive is a silent success in the *wrong application* that the
    /// model then builds a plan on, while a false negative costs one extra
    /// verification step in the one place the agent was never asked to drive.
    public func isSelfNoise(since previous: UIFingerprint, selfBundleIDs: [String]) -> Bool {
        guard let bundleIdentifier, selfBundleIDs.contains(bundleIdentifier) else { return false }
        // A value that did not change is not noise to discount — it is the identical
        // fingerprint the caller already reports as "no observable change". Requiring
        // the difference keeps this answer usable as "suppression actually fired",
        // which is what the returned text has to be honest about.
        return previous.focusedValue != focusedValue
            && previous.bundleIdentifier == bundleIdentifier
            && previous.windowTitle == windowTitle
            && previous.focusedRole == focusedRole
            && previous.focusedTitle == focusedTitle
            && scrollMovement(since: previous) == nil
    }

    /// Whether this app exposed a focused element at all when the sample was taken.
    ///
    /// The cheap proxy for "this app does not publish an accessibility tree". Measured
    /// on this machine, reading only the fields the cheap path already reads:
    ///
    ///     VS Code   focusedWindow resolves,  focusedElement nil
    ///     Chrome    focusedWindow resolves,  focusedElement nil
    ///     Finder    focusedWindow nil,       focusedElement AXGroup
    ///     Terminal  focusedWindow resolves,  focusedElement AXTextArea
    ///
    /// So the signal is the *element*, not the window: Finder resolves no focused
    /// window merely because none is open, and it is perfectly observable. Costs
    /// nothing — `focusedRole` is already one of the five attribute reads, and the
    /// tree walk `AXTree.Capture.isEffectivelyEmpty` needs is deliberately kept off
    /// the polling path.
    var exposesFocus: Bool { focusedRole != nil }

    private func describeFocus() -> String {
        guard let focusedRole else { return "nothing" }
        let role = focusedRole.replacingOccurrences(of: "AX", with: "")
        guard let focusedTitle, !focusedTitle.isEmpty else { return role }
        return "\(role) \"\(focusedTitle.truncated(60))\""
    }

    /// The value to report for an element, redacting secure fields.
    ///
    /// Both the fingerprint and the full accessibility capture read element values,
    /// and each applied this check itself — so removing it from either was invisible
    /// to the tests. One function, used by both, is testable and cannot be half-applied.
    public static func reportableValue(
        role: String?, subrole: String?, label: String? = nil, value: String?
    ) -> String? {
        isSecure(role: role, subrole: subrole, label: label) ? "(secure field)" : value
    }

    /// Whether an element is a password or otherwise secure input.
    static func isSecure(role: String?, subrole: String?, label: String? = nil) -> Bool {
        let roles = [role, subrole].compactMap { $0?.lowercased() }
        if roles.contains(where: { $0.contains("secure") || $0.contains("password") }) {
            return true
        }

        // The role is not the only evidence. `AXSecureTextField` is caught above, but
        // a field an app draws with an ordinary role and the label "Password" holds
        // exactly the same thing — and a capture reads every node's value, so one such
        // field puts its contents in the model's context and in a session record kept
        // in full and never pruned. Over-redacting something merely *labelled* a
        // secret costs a line of a capture; under-redacting costs the secret.
        guard let label = label?.lowercased(), !label.isEmpty else { return false }
        return secretLabels.contains { label.contains($0) }
    }

    private static let secretLabels = [
        "password", "passphrase", "passcode", "secret", "api key", "apikey",
        "access key", "private key", "token", "credential", "pin code",
        "security code", "verification code", "recovery key", "seed phrase",
    ]

    // MARK: - Accessibility helpers

    /// The vertical offset of every scroll area in the window, 0...1, in the order a
    /// breadth-first walk finds them.
    ///
    /// Bounded rather than a full tree read, because this runs on every verified
    /// action and has to stay in the same cost class as the five reads around it.
    /// The bound is why the result is positional: two fingerprints are only compared
    /// when they found the same number of areas, so a truncated walk cannot make two
    /// unrelated panes look like one that moved.
    private static func scrollOffsets(in window: AXUIElement?) -> [Double] {
        guard let window else { return [] }
        var frontier = [window]
        var offsets: [Double] = []
        var visited = 0

        while !frontier.isEmpty, visited < nodeBudget {
            var next: [AXUIElement] = []
            for element in frontier {
                visited += 1
                if visited > nodeBudget { break }

                // Role, scroll bar and children in one round trip. Each of these is
                // IPC to the target app, and reading them separately made a window
                // with no scroll area near the top cost 23ms — a fingerprint is taken
                // repeatedly while polling for a change, so that is the whole settle
                // budget spent looking.
                var raw: CFArray?
                let status = AXUIElementCopyMultipleAttributeValues(
                    element, Self.scrollAttributes as CFArray,
                    AXCopyMultipleAttributeOptions(), &raw
                )
                let values = (status == .success ? raw as? [AnyObject] : nil) ?? []
                func value(_ index: Int) -> AnyObject? {
                    guard index < values.count else { return nil }
                    let candidate = values[index]
                    // A missing attribute comes back as an AXValue wrapping an AXError
                    // rather than as a gap, so it has to be filtered out by type.
                    if CFGetTypeID(candidate) == AXValueGetTypeID(),
                       AXValueGetType(candidate as! AXValue) == .axError { return nil }
                    return candidate
                }

                // The scroll bar comes back from a batched read with no type promise,
                // so it is checked rather than force-cast: an app returning something
                // else for this attribute would crash the fingerprint, which runs
                // after every single action.
                if value(0) as? String == "AXScrollArea", let bar = value(1),
                   CFGetTypeID(bar) == AXUIElementGetTypeID() {
                    if let offset = string(of: (bar as! AXUIElement), kAXValueAttribute)
                        .flatMap(Double.init) {
                        offsets.append(offset)
                    }
                    continue   // a scroll area's own children are not scroll areas
                }
                if let list = value(2) as? [AXUIElement] {
                    next.append(contentsOf: list.prefix(12))
                }
            }
            frontier = next
        }
        return offsets
    }

    /// How many elements the scroll walk may visit. Bounds the cost of a window built
    /// from deep nesting; a split view's panes are found well inside it.
    private static let nodeBudget = 48

    /// Held as strings and bridged per call: a static `CFArray` is not Sendable.
    private static let scrollAttributes = [
        kAXRoleAttribute, kAXVerticalScrollBarAttribute, kAXChildrenAttribute,
    ]

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        // Only bridge back when the value really is an element; some attributes
        // return strings or numbers and force-casting them crashes.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(of element: AXUIElement?, _ attribute: String) -> String? {
        guard let element else { return nil }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Runs an action between two fingerprints and describes the outcome.
///
/// Centralised so every action tool reports verification the same way, and so the
/// "nothing changed" wording — the part that has to prompt a different strategy
/// rather than a repeat of the same click — is written once.
public enum Verified {
    /// What a verification actually concluded — the words the model reads, and the
    /// verdict underneath them.
    ///
    /// The verdict used to exist only inside the prose. `act` computed it, phrased it
    /// as "No observable change: …", and returned a `String`; every caller wrapped
    /// that in `.text(...)` and the fact was gone. Session
    /// `39BAB4C3-478C-4D37-9933-9E2C5E2DDC45` is what that cost: asked to
    /// "press cmd+shift+p to open the command palette", the `key` tool returned
    /// "Pressed cmd+shift+p. No observable change: the frontmost app, window and
    /// focused element are all as they were.", the model read it correctly and wrote
    /// "The command palette didn't open." — and the run still recorded
    /// `act=1 obs=1 unfulfilled=False`, closed on `end_turn` and exited 0. The one
    /// layer that knew the keystroke had done nothing was the only layer that could
    /// not tell anyone but the model.
    ///
    /// So the verdict travels as a value. Recovering it downstream by searching the
    /// text for "No observable change" would be the same defect wearing a different
    /// hat: this wording is a UI string written to be rewritten, and a caller that
    /// depends on its phrasing breaks silently the first time it is reworded — the
    /// argument `ScriptTools.containsWord` makes about matching prose, applied to our
    /// own prose.
    public struct Outcome: Sendable, Equatable {
        /// The sentence handed back to the model. Unchanged in wording by this type.
        public let report: String

        /// Whether the check found evidence the action did something.
        ///
        /// False covers both ways of finding nothing: a fingerprint that did not move
        /// at all, and one whose only movement was the agent's own window redrawing —
        /// `evidence(_:)` returning nil is the single source of both, so suppressed
        /// self-noise is not evidence of change here either. That composition is the
        /// measured session above: a keystroke into a terminal that was scrolling its
        /// own output.
        public let observedChange: Bool

        /// Whether the app exposed anything for the check to read.
        ///
        /// False means the check was blind, not that the action failed. Kept apart
        /// from `observedChange` because "nothing moved" and "nothing could be seen"
        /// are different findings, and reporting the second as the first is what sends
        /// the model away from a strategy that worked.
        public let couldObserve: Bool

        public init(report: String, observedChange: Bool, couldObserve: Bool = true) {
            self.report = report
            self.observedChange = observedChange
            self.couldObserve = couldObserve
        }
    }

    /// How often to re-check while waiting for the UI to respond.
    ///
    /// A polling fingerprint costs ~0.25ms, so a full 300ms settle spends about 4ms
    /// on IPC — and exits early the moment something changes. The scroll walk is not
    /// on this path; see `captureIncludingScroll`.
    private static let pollInterval = Duration.milliseconds(20)

    /// - Parameter selfBundleIDs: the agent's own surfaces — the menu bar app's own
    ///   bundle, and for the CLI the terminal it is printing into. A value change in
    ///   one of these is the agent watching itself and is not evidence; see
    ///   `UIFingerprint.isSelfNoise(since:selfBundleIDs:)` for the measurement and the
    ///   trade-off. Empty — the default — behaves exactly as before.
    ///
    ///   Passed in rather than discovered here. Which surfaces are "the agent's own"
    ///   is a fact about the *process*, not about an action, and the one place that
    ///   knows it is the executable that built the registry — the same route
    ///   `ScreenshotTool.excludedBundleIDs` already takes for the same reason.
    ///
    /// - Parameter capture: how to sample the UI, given whether the sample must
    ///   include scroll offsets. Injectable so the polling itself can be tested
    ///   deterministically — otherwise "it returns early when the UI changes" is an
    ///   assumption rather than a verified property.
    ///
    ///   One closure taking a flag rather than two closures: separate seams could be
    ///   injected inconsistently, and a test that stubbed the polling while the
    ///   baseline came from the real machine compared two unrelated windows.
    public static func act(
        describing description: String,
        selfBundleIDs: [String] = [],
        settle: Duration = .milliseconds(300),
        capture: @Sendable (_ includingScroll: Bool) -> UIFingerprint = {
            $0 ? UIFingerprint.captureIncludingScroll() : UIFingerprint.capture()
        },
        _ action: () async throws -> Void
    ) async rethrows -> Outcome {
        let before = capture(true)
        try await action()

        /// What actually counts as the action having landed: a change that is not
        /// merely one of the agent's own surfaces redrawing.
        ///
        /// Used by the poll loop as well as the verdict, deliberately. Asking only at
        /// the end would break out of polling on the first frame the host terminal
        /// printed a line — which is immediately, every time — and then discount it,
        /// turning a slow app's genuine response into "no observable change". The
        /// settle budget has to be spent waiting for real evidence.
        func evidence(_ after: UIFingerprint) -> String? {
            guard let changes = after.changes(since: before),
                  !after.isSelfNoise(since: before, selfBundleIDs: selfBundleIDs)
            else { return nil }
            return changes
        }

        // Poll rather than sleeping a fixed interval. The wait exists because a
        // fingerprint taken before the window redraws reports every action as a
        // no-op — but a responsive app changes within a frame, and a fixed sleep
        // makes every action pay the worst case. A batch of ten clicks was over a
        // second of pure waiting.
        //
        // The budget is generous because the two failure modes are not symmetric: a
        // premature "nothing changed" tells the model to abandon a strategy that
        // actually worked, whereas waiting longer merely costs time on the rarer
        // path where the action genuinely missed.
        var after = before
        let deadline = ContinuousClock.now + settle
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            after = capture(false)
            if evidence(after) != nil { break }
        }

        // Nothing obvious moved, so ask the expensive question once: did anything
        // scroll? Polling with this would spend the whole settle budget on IPC, and a
        // scroll is invisible to the cheap fingerprint anyway — there is nothing to
        // detect early.
        if evidence(after) == nil {
            after = capture(true)
        }

        guard let changes = evidence(after) else {
            // Suppression that says nothing would be a second invisible mechanism —
            // the same class of defect as the false confirmation it replaces. If the
            // only thing that moved was the agent's own window, the model is told so
            // and told why, so it can read this as "not yet verified" rather than as
            // a mysterious no-op.
            let ignored = after.isSelfNoise(since: before, selfBundleIDs: selfBundleIDs)
                ? " A value change in \(after.appName) — the agent's own window, whose text changes on its own — was ignored, not counted as evidence."
                : ""
            // An app that exposes no focused element was never being watched, so
            // "nothing changed" is not a finding about the action — it is the absence
            // of one, and the advice below ("it may have missed, try something else")
            // asserts something unmeasured. VS Code, Chrome, Slack and Discord all
            // publish nothing here. Measured: `key cmd+shift+p` into a confirmed
            // frontmost VS Code reported no change, while the same tool opened and
            // saw Finder's Go To Folder dialog. The keystroke worked; the check was
            // blind. Telling the model it probably missed is how a working strategy
            // gets abandoned.
            if !before.exposesFocus, !after.exposesFocus {
                return Outcome(report: """
                \(description). Cannot confirm: \(after.appName) publishes no accessibility \
                tree, so there is nothing here to read either before or after — common for \
                Electron apps such as VS Code, Slack and Discord. This is not evidence the \
                action missed; it is the absence of evidence either way, and repeating it \
                or switching strategy on the strength of it would be guessing. Confirm \
                another way: a screenshot if this run has tier 3, or a tier 0 or tier 1 \
                check against the app's own state.
                """, observedChange: false, couldObserve: false)
            }
            return Outcome(report: """
            \(description). No observable change: the frontmost app, window and focused \
            element are all as they were.\(ignored) The action may have missed, or it may \
            have had an effect this check cannot see. Verify before continuing — and if it \
            did miss, do not repeat the same coordinates: re-run ax_capture and act on an \
            element id, or use a keyboard shortcut.
            """, observedChange: false)
        }
        return Outcome(report: "\(description). \(changes).", observedChange: true)
    }
}
