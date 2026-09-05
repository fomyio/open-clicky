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
/// Measured at 1.3ms, of which about 1ms is the bounded walk for a scroll area; the
/// rest is five attribute reads.
public struct UIFingerprint: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitle: String?
    public let focusedRole: String?
    public let focusedTitle: String?
    public let focusedValue: String?
    /// Where the frontmost scrollable view sits, 0...1.
    ///
    /// Without it a scroll was invisible to verification: the frontmost app, window
    /// and focused element are all identical before and after one, so every scroll —
    /// the ones that worked included — reported "no observable change" and told the
    /// model to abandon a strategy that may have been fine.
    public let scrollPosition: Double?

    public init(bundleIdentifier: String?, appName: String, windowTitle: String?,
                focusedRole: String?, focusedTitle: String?, focusedValue: String?,
                scrollPosition: Double? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedRole = focusedRole
        self.focusedTitle = focusedTitle
        self.focusedValue = focusedValue
        self.scrollPosition = scrollPosition
    }

    public static func capture() -> UIFingerprint {
        let app = NSWorkspace.shared.frontmostApplication
        var windowTitle: String?
        var role: String?
        var title: String?
        var value: String?
        var scrollPosition: Double?

        if AXIsProcessTrusted(), let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            // A hung app must not stall the action loop.
            AXUIElementSetMessagingTimeout(axApp, 1.0)

            let window = copy(axApp, kAXFocusedWindowAttribute)
            windowTitle = string(of: window, kAXTitleAttribute)
            scrollPosition = scrollOffset(in: window)
            if let focused = copy(axApp, kAXFocusedUIElementAttribute) {
                role = string(of: focused, kAXRoleAttribute)
                title = string(of: focused, kAXTitleAttribute)
                let subrole = string(of: focused, kAXSubroleAttribute)
                // Never read a password field's contents. AppKit's own secure fields
                // mask their AX value, but web and custom controls do not always, and
                // this value would otherwise reach the model and the transcript.
                value = reportableValue(
                    role: role, subrole: subrole,
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
            scrollPosition: scrollPosition
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

        // A tolerance, because a scroll view can settle a fraction of a pixel on its
        // own; anything a scroll actually moved is orders of magnitude larger.
        if let previousOffset = previous.scrollPosition, let scrollPosition,
           abs(previousOffset - scrollPosition) > 0.0001 {
            let direction = scrollPosition > previousOffset ? "down" : "up"
            notes.append("scrolled \(direction) to \(Int((scrollPosition * 100).rounded()))%")
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
    public static func reportableValue(role: String?, subrole: String?, value: String?) -> String? {
        isSecure(role: role, subrole: subrole) ? "(secure field)" : value
    }

    /// Whether an element is a password or otherwise secure input.
    static func isSecure(role: String?, subrole: String?) -> Bool {
        let candidates = [role, subrole].compactMap { $0?.lowercased() }
        return candidates.contains { $0.contains("secure") || $0.contains("password") }
    }

    // MARK: - Accessibility helpers

    /// The vertical scroll offset of the first scroll area in the window, 0...1.
    ///
    /// A bounded breadth-first walk rather than a full tree read: the scroll area is
    /// near the top in every app tried, and this runs on every verified action, so it
    /// must stay in the same cost class as the five reads around it.
    private static func scrollOffset(in window: AXUIElement?) -> Double? {
        guard let window else { return nil }
        var frontier = [window]
        var visited = 0

        while !frontier.isEmpty, visited < 48 {
            var next: [AXUIElement] = []
            for element in frontier {
                visited += 1
                if visited > 48 { break }
                if string(of: element, kAXRoleAttribute) == "AXScrollArea",
                   let bar = copy(element, kAXVerticalScrollBarAttribute),
                   let value = string(of: bar, kAXValueAttribute).flatMap(Double.init) {
                    return value
                }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                    == .success, let list = children as? [AXUIElement] {
                    next.append(contentsOf: list.prefix(12))
                }
            }
            frontier = next
        }
        return nil
    }

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
    /// A fingerprint costs about 1.3ms, so a full 300ms settle spends at most ~20ms
    /// polling — and exits early the moment something changes.
    private static let pollInterval = Duration.milliseconds(20)

    /// - Parameter capture: how to sample the UI. Injectable so the polling itself
    ///   can be tested deterministically — otherwise "it returns early when the UI
    ///   changes" is an assumption rather than a verified property.
    public static func act(
        describing description: String,
        settle: Duration = .milliseconds(300),
        capture: @Sendable () -> UIFingerprint = { UIFingerprint.capture() },
        _ action: () async throws -> Void
    ) async rethrows -> String {
        let before = capture()
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
            after = capture()
            if after.changes(since: before) != nil { break }
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
