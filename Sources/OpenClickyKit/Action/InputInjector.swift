import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

/// Synthesises mouse and keyboard input at the OS level via CGEvent.
///
/// Coordinates here are always *screen points, top-left origin* — the space
/// CGEvent and the accessibility API share. Anything arriving in image pixels
/// must be converted through `Screenshot.screenPoint(fromImage:)` first.
public enum InputInjector {

    public enum Error: Swift.Error, CustomStringConvertible {
        case notTrusted
        case unknownKey(String)
        case eventCreationFailed

        public var description: String {
            switch self {
            case .notTrusted:
                return """
                Accessibility permission is not granted, so synthetic input is ignored \
                by the system. Grant it in System Settings ▸ Privacy & Security ▸ \
                Accessibility, then try again.
                """
            case let .unknownKey(key):
                return "Unrecognised key '\(key)'. Use a character, or a name like Return, Tab, Escape, Left, F5."
            case .eventCreationFailed:
                return "The system refused to create the input event."
            }
        }
    }

    public enum MouseButton: String, Sendable {
        case left, right, middle

        var down: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            case .middle: return .otherMouseDown
            }
        }
        var up: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            case .middle: return .otherMouseUp
            }
        }
        var dragType: CGEventType {
            switch self {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            case .middle: return .otherMouseDragged
            }
        }
        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            case .middle: return .center
            }
        }
    }

    private static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Mouse

    public static func move(to point: CGPoint) throws {
        try post(mouse: .mouseMoved, at: point, button: .left, clickCount: 0)
    }

    public static func click(
        at point: CGPoint, button: MouseButton = .left, count: Int = 1
    ) throws {
        // Move first and let the UI settle: many controls only reveal their hit
        // target on hover, and clicking without a preceding move misses them.
        try move(to: point)
        usleep(30_000)
        for index in 1...max(count, 1) {
            try post(mouse: button.down, at: point, button: button, clickCount: index)
            usleep(20_000)
            try post(mouse: button.up, at: point, button: button, clickCount: index)
            if index < count { usleep(60_000) }
        }
    }

    public static func drag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left) throws {
        try move(to: start)
        usleep(40_000)
        try post(mouse: button.down, at: start, button: button, clickCount: 1)

        // Interpolate: a single jump from start to end reads as a teleport and many
        // drag handlers (sliders, selections, drag-and-drop) never engage.
        let steps = 24
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            try post(mouse: button.dragType, at: point, button: button, clickCount: 1)
            usleep(8_000)
        }
        try post(mouse: button.up, at: end, button: button, clickCount: 1)
    }

    public static func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {
        guard isTrusted else { throw Error.notTrusted }
        if let point { try move(to: point); usleep(20_000) }

        // Break the scroll into steps so momentum-aware views track it as a gesture.
        let steps = max(abs(deltaX), abs(deltaY)) > 10 ? 6 : 1
        for _ in 0..<steps {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(deltaY / steps), wheel2: Int32(deltaX / steps), wheel3: 0
            ) else { throw Error.eventCreationFailed }
            event.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }

    public static var cursorPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func post(
        mouse type: CGEventType, at point: CGPoint, button: MouseButton, clickCount: Int
    ) throws {
        guard isTrusted else { throw Error.notTrusted }
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: button.cgButton
        ) else { throw Error.eventCreationFailed }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Types literal text.
    ///
    /// Short strings go through synthetic key events. Longer or multi-line text is
    /// pasted via the clipboard: per-character events drop and reorder under load,
    /// and are painfully slow past a few dozen characters.
    public static func type(_ text: String, viaClipboardAbove threshold: Int = 60) throws {
        guard isTrusted else { throw Error.notTrusted }
        guard !text.isEmpty else { return }

        if text.count > threshold || text.contains("\n") {
            try paste(text)
            return
        }
        for chunk in text.chunked(into: 16) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw Error.eventCreationFailed
            }
            var utf16 = Array(chunk.utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            usleep(6_000)
            up.post(tap: .cghidEventTap)
            usleep(6_000)
        }
    }

    /// Puts text on the clipboard and sends Cmd+V, restoring the previous contents.
    private static func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        usleep(40_000)

        try key(combo: "cmd+v")
        usleep(120_000)

        // Restore so the agent does not silently clobber the user's clipboard.
        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    /// Parses a combination such as `cmd+s`, `ctrl+shift+Tab` or `Escape`.
    ///
    /// Separated from posting so it can be tested: exercising `key(combo:)` directly
    /// would type into whatever happens to have focus.
    static func parse(combo: String) throws -> (flags: CGEventFlags, keyCode: CGKeyCode) {
        let parts = combo.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let keyName = parts.last else { throw Error.unknownKey(combo) }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: throw Error.unknownKey(String(modifier))
            }
        }

        guard let keyCode = KeyMap.code(for: keyName) else { throw Error.unknownKey(keyName) }
        return (flags, keyCode)
    }

    /// Sends a key combination such as `cmd+s`, `ctrl+shift+Tab`, or `Escape`.
    public static func key(combo: String, repeatCount: Int = 1) throws {
        guard isTrusted else { throw Error.notTrusted }
        let (flags, keyCode) = try parse(combo: combo)

        for _ in 0..<max(repeatCount, 1) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                throw Error.eventCreationFailed
            }
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            usleep(20_000)
            up.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }
}

/// Maps key names to macOS virtual key codes.
enum KeyMap {
    private static let named: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
        "forwarddelete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "help": CGKeyCode(kVK_Help),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
        "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
        "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
    ]

    /// US-layout characters. Non-ASCII text should go through `type` instead,
    /// which is layout-independent because it sets the unicode string directly.
    private static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    static func code(for name: String) -> CGKeyCode? {
        if let code = named[name.lowercased()] { return code }
        if name.count == 1, let character = name.lowercased().first {
            return characters[character]
        }
        return nil
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        guard count > size else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: Swift.min(size, count - $0))
            return String(self[start..<end])
        }
    }
}
