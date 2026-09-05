import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

/// Where pointer actions go.
///
/// A seam, so a test can observe the screen point a tool computed without a mouse
/// actually moving. The coordinate conversion is the whole reason clicks land where
/// they were meant to, and until this existed nothing verified that `click` applied
/// it — a tool treating image pixels as screen points passed the entire suite.
public protocol PointerActing: Sendable {
    func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws
    func drag(from start: CGPoint, to end: CGPoint) throws
    func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws
}

/// The real pointer.
public struct SystemPointer: PointerActing {
    public init() {}

    public func click(at point: CGPoint, button: InputInjector.MouseButton, count: Int) throws {
        try InputInjector.click(at: point, button: button, count: count)
    }
    public func drag(from start: CGPoint, to end: CGPoint) throws {
        try InputInjector.drag(from: start, to: end)
    }
    public func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {
        try InputInjector.scroll(deltaX: deltaX, deltaY: deltaY, at: point)
    }
}

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

    /// Splits a scroll into per-step deltas that sum to exactly what was asked for.
    ///
    /// A scroll is delivered in several events so momentum-aware views track it as a
    /// gesture rather than a jump. Dividing the total by the step count loses the
    /// remainder to integer truncation, and the loss is worst where it is least
    /// affordable: a request to scroll 11 pixels delivered 6, and 100 delivered 96.
    /// The model sees less movement than it asked for, and scrolls again — or decides
    /// the view did not respond.
    ///
    /// Pure, so the arithmetic can be checked without moving anything on screen.
    static func scrollSteps(deltaX: Int, deltaY: Int) -> [(x: Int, y: Int)] {
        let count = max(abs(deltaX), abs(deltaY)) > 10 ? 6 : 1
        guard count > 1 else { return [(deltaX, deltaY)] }

        /// Distributes `total` over `count` steps, spreading the remainder one unit
        /// at a time so the sum is exact whatever the sign.
        func spread(_ total: Int) -> [Int] {
            let sign = total < 0 ? -1 : 1
            let magnitude = abs(total)
            let base = magnitude / count
            let remainder = magnitude % count
            return (0..<count).map { sign * (base + ($0 < remainder ? 1 : 0)) }
        }

        let xs = spread(deltaX)
        let ys = spread(deltaY)
        return (0..<count).map { (xs[$0], ys[$0]) }
    }

    public static func scroll(deltaX: Int, deltaY: Int, at point: CGPoint?) throws {
        guard isTrusted else { throw Error.notTrusted }
        if let point { try move(to: point); usleep(20_000) }

        for step in scrollSteps(deltaX: deltaX, deltaY: deltaY) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(step.y), wheel2: Int32(step.x), wheel3: 0
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
    /// How a piece of text should be entered.
    public enum TypingStrategy: Equatable, Sendable {
        /// Synthetic key events, one chunk at a time.
        case keystrokes
        /// Clipboard paste, restoring the previous contents afterwards.
        case clipboard
    }

    /// Chooses between them.
    ///
    /// Per-character events drop and reorder under load and are painfully slow past a
    /// few dozen characters, and a newline typed as Return submits forms rather than
    /// entering a line break. Extracted from the posting so the choice can be checked
    /// without typing into whatever has focus.
    static func typingStrategy(for text: String, threshold: Int = 60) -> TypingStrategy {
        text.count > threshold || text.contains("\n") ? .clipboard : .keystrokes
    }

    public static func type(_ text: String, viaClipboardAbove threshold: Int = 60) throws {
        guard isTrusted else { throw Error.notTrusted }
        guard !text.isEmpty else { return }

        if typingStrategy(for: text, threshold: threshold) == .clipboard {
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

    /// Everything on a pasteboard, copied out so the contents survive `clearContents()`.
    ///
    /// Returns `nil` only when the pasteboard cannot be read, which is distinct from an
    /// empty one: an empty clipboard is a state worth restoring faithfully, an
    /// unreadable one is a reason not to touch it.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems.map { items in
            var budget = clipboardByteBudget
            return items.map { item in
                let copy = NSPasteboardItem()
                for type in item.types where !Self.isPromised(type) {
                    guard budget > 0, let data = item.data(forType: type) else { continue }
                    budget -= data.count
                    copy.setData(data, forType: type)
                }
                return copy
            }
        }
    }

    /// Types whose data the owning app produces on demand.
    ///
    /// `data(forType:)` on one of these is a synchronous round trip to that app, which
    /// may be busy or gone — and this runs on the path that types text, so a hung
    /// clipboard owner would stall the agent rather than fail it. A promise cannot be
    /// preserved by copying bytes anyway; what is dropped here would have been dropped
    /// by the old string-only snapshot too.
    private static func isPromised(_ type: NSPasteboard.PasteboardType) -> Bool {
        let name = type.rawValue
        return name.contains("promise") || name.contains("promised")
            || name == "com.apple.NSFilePromiseItemMetaData"
    }

    /// How much clipboard content is copied out before the rest is left behind.
    ///
    /// A clipboard can hold a video. Restoring one is not worth holding it twice in
    /// memory through a keystroke, and the alternative to a partial restore is the
    /// previous behaviour: no restore at all for anything that was not a string.
    private static let clipboardByteBudget = 32 * 1024 * 1024

    /// Whether the pasteboard still holds what we last wrote to it.
    ///
    /// Separated so the race can be tested: the window is milliseconds wide and the
    /// loss is silent, which is the combination that never shows up in use.
    static func isUnchanged(_ pasteboard: NSPasteboard, since changeCount: Int) -> Bool {
        pasteboard.changeCount == changeCount
    }

    static func restore(_ items: [NSPasteboardItem]?, to pasteboard: NSPasteboard) {
        guard let items else { return }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Puts text on the clipboard and sends Cmd+V, restoring the previous contents.
    private static func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        // Restore on every exit path. Without a defer, a throw from `key` — the
        // Accessibility grant being revoked mid-session is enough — left the user's
        // clipboard permanently replaced by the agent's text, and whatever they had
        // copied (possibly a password or a one-time code) gone.
        //
        // The snapshot has to be every type, not `string(forType:)`. A copied image,
        // file or styled snippet read back as nil, so the restore was skipped and the
        // user was left holding the agent's text — the precise loss this defer exists
        // to prevent, for every clipboard that was not plain text.
        // Only if the clipboard is still the one we put there. The paste holds it for
        // about 160ms, and a person who copies something in that window would
        // otherwise have their new clipboard silently replaced by a snapshot of what
        // they had before — the agent restoring the user's data over the top of the
        // user's data.
        var ours = pasteboard.changeCount
        defer {
            if isUnchanged(pasteboard, since: ours) { restore(saved, to: pasteboard) }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ours = pasteboard.changeCount
        usleep(40_000)

        try key(combo: "cmd+v")
        usleep(120_000)
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
