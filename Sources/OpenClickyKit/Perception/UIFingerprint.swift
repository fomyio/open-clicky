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
/// Deliberately tiny — a handful of accessibility reads and around fifty tokens.
/// A full `ax_capture` after every click would cost more than the click saved.
public struct UIFingerprint: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitle: String?
    public let focusedRole: String?
    public let focusedTitle: String?
    public let focusedValue: String?

    public static func capture() -> UIFingerprint {
        let app = NSWorkspace.shared.frontmostApplication
        var windowTitle: String?
        var role: String?
        var title: String?
        var value: String?

        if AXIsProcessTrusted(), let pid = app?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            // A hung app must not stall the action loop.
            AXUIElementSetMessagingTimeout(axApp, 1.0)

            windowTitle = string(of: copy(axApp, kAXFocusedWindowAttribute), kAXTitleAttribute)
            if let focused = copy(axApp, kAXFocusedUIElementAttribute) {
                role = string(of: focused, kAXRoleAttribute)
                title = string(of: focused, kAXTitleAttribute)
                value = string(of: focused, kAXValueAttribute)
            }
        }

        return UIFingerprint(
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName ?? "unknown",
            windowTitle: windowTitle,
            focusedRole: role,
            focusedTitle: title,
            focusedValue: value
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

        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    private func describeFocus() -> String {
        guard let focusedRole else { return "nothing" }
        let role = focusedRole.replacingOccurrences(of: "AX", with: "")
        guard let focusedTitle, !focusedTitle.isEmpty else { return role }
        return "\(role) \"\(focusedTitle.truncated(60))\""
    }

    // MARK: - Accessibility helpers

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
    public static func act(
        describing description: String,
        settle: Duration = .milliseconds(180),
        _ action: () async throws -> Void
    ) async rethrows -> String {
        let before = UIFingerprint.capture()
        try await action()

        // Let the UI respond. Without this the fingerprint is taken before the
        // window has redrawn and every action reports as having done nothing.
        try? await Task.sleep(for: settle)

        let after = UIFingerprint.capture()
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
