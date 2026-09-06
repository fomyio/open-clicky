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
        if previous.focusedRole != focusedRole || previous.focusedTitle != focusedTitle {
            notes.append("focus is now on \(describeFocus())")
        } else if previous.focusedValue != focusedValue {
            notes.append("the focused element's value changed to \(focusedValue.map { "\"\($0.truncated(60))\"" } ?? "empty")")
        }

        // Any pane that moved counts. Comparing only when the counts match: a window
        // that gained or lost a scroll area changed structurally, and calling that
        // "scrolled" would be a false positive in place of the false negative.
        //
        // The tolerance is because a scroll view can settle a fraction of a pixel on
        // its own; anything a scroll actually moved is orders of magnitude larger.
        if previous.scrollPositions.count == scrollPositions.count,
           let moved = zip(previous.scrollPositions, scrollPositions)
               .first(where: { abs($0 - $1) > 0.0001 }) {
            let direction = moved.1 > moved.0 ? "down" : "up"
            notes.append("scrolled \(direction) to \(Int((moved.1 * 100).rounded()))%")
        }

        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

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
    /// How often to re-check while waiting for the UI to respond.
    ///
    /// A polling fingerprint costs ~0.25ms, so a full 300ms settle spends about 4ms
    /// on IPC — and exits early the moment something changes. The scroll walk is not
    /// on this path; see `captureIncludingScroll`.
    private static let pollInterval = Duration.milliseconds(20)

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
        settle: Duration = .milliseconds(300),
        capture: @Sendable (_ includingScroll: Bool) -> UIFingerprint = {
            $0 ? UIFingerprint.captureIncludingScroll() : UIFingerprint.capture()
        },
        _ action: () async throws -> Void
    ) async rethrows -> String {
        let before = capture(true)
        try await action()

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
            if after.changes(since: before) != nil { break }
        }

        // Nothing obvious moved, so ask the expensive question once: did anything
        // scroll? Polling with this would spend the whole settle budget on IPC, and a
        // scroll is invisible to the cheap fingerprint anyway — there is nothing to
        // detect early.
        if after.changes(since: before) == nil {
            after = capture(true)
        }

        guard let changes = after.changes(since: before) else {
            return """
            \(description). No observable change: the frontmost app, window and focused \
            element are all as they were. The action may have missed, or it may have had \
            an effect this check cannot see. Verify before continuing — and if it did \
            miss, do not repeat the same coordinates: re-run ax_capture and act on an \
            element id, or use a keyboard shortcut.
            """
        }
        return "\(description). \(changes)."
    }
}
