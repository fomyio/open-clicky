import Foundation
import AppKit
import ApplicationServices

/// A cheap snapshot of what the user is looking at.
///
/// Prepended to the opening user message, once, so the model starts oriented — which
/// app is front, what the window is, what displays exist — for about fifty tokens
/// instead of the ~1,500 a screenshot costs.
///
/// Deliberately not refreshed each turn, though it goes stale the moment anything
/// activates a different app. Every `ax_capture` names the app it read on its first
/// line, and `UIFingerprint` reports a change of frontmost app after any action, so
/// the model learns the current app at the point it matters. Repeating this every
/// turn would restate what those already say, and a line that is usually redundant is
/// a line that stops being read.
public struct ContextProbe: Sendable {
    public let frontmostApp: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let displays: [String]
    public let timestamp: Date

    public static func capture() -> ContextProbe {
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication

        var windowTitle: String?
        if AXIsProcessTrusted(), let pid = front?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 1.0)
            var window: AnyObject?
            if AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString, &window
            ) == .success, let window {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(
                    window as! AXUIElement, kAXTitleAttribute as CFString, &title
                ) == .success {
                    windowTitle = title as? String
                }
            }
        }

        let displays = NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            let main = screen == NSScreen.main ? " (main)" : ""
            return "display \(index): \(Int(frame.width))×\(Int(frame.height)) pt\(main)"
        }

        return ContextProbe(
            frontmostApp: front?.localizedName ?? "unknown",
            bundleIdentifier: front?.bundleIdentifier,
            windowTitle: windowTitle,
            displays: displays,
            timestamp: Date()
        )
    }

    /// Rendered for the model. Kept terse: it is the first thing in the first turn.
    public var rendered: String {
        var lines = ["<environment>"]
        lines.append("time: \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("frontmost app: \(frontmostApp)\(bundleIdentifier.map { " (\($0))" } ?? "")")
        if let windowTitle { lines.append("focused window: \(windowTitle)") }
        lines.append(contentsOf: displays)
        lines.append("</environment>")
        return lines.joined(separator: "\n")
    }
}

/// Whether the TCC grants OpenClicky needs are in place.
public struct PermissionStatus: Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool

    public static func current() -> PermissionStatus {
        PermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    public var allGranted: Bool { screenRecording && accessibility }

    /// What is missing and how to fix it, or nil when everything is granted.
    public var advice: String? {
        guard !allGranted else { return nil }
        var lines = ["Missing macOS permissions:"]
        if !accessibility {
            lines.append("  • Accessibility — needed to read windows and to click/type.")
            lines.append("    System Settings ▸ Privacy & Security ▸ Accessibility")
        }
        if !screenRecording {
            lines.append("  • Screen Recording — needed for screenshots.")
            lines.append("    System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording")
        }
        lines.append("")
        lines.append("Tiers 0 and 1 (shell, AppleScript) work without either.")
        return lines.joined(separator: "\n")
    }
}
