import Foundation
import Carbon.HIToolbox

/// A global hotkey registration.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor: a monitor
/// observes the keystroke but does not consume it, so the trigger would also reach
/// whatever app has focus. For a hotkey that fires while the user is mid-sentence in
/// another app, that is not acceptable.
public final class HotKey {

    public struct Combination: Equatable, Sendable {
        public let keyCode: UInt32
        public let carbonModifiers: UInt32
        public let display: String

        public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
            self.display = display
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unparseable(String)
        case noModifier(String)
        /// Modifiers but nothing to press: `cmd+`, or `cmd` on its own.
        case missingKey(String)
        case registrationFailed(OSStatus)

        public var description: String {
            switch self {
            case let .unparseable(combo):
                return "Could not parse the hotkey '\(combo)'. Use something like 'opt+space' or 'cmd+shift+k'."
            case let .noModifier(combo):
                return "The hotkey '\(combo)' has no modifier. A bare key would fire while you were typing — use at least one of cmd, ctrl, opt or shift."
            case let .missingKey(combo):
                return "The hotkey '\(combo)' names modifiers but no key. Add one, as in 'opt+space'."
            case let .registrationFailed(status):
                return "Another application already owns this hotkey (OSStatus \(status)). Choose a different one."
            }
        }
    }

    /// Parses a combination such as `opt+space` or `cmd+shift+k`.
    ///
    /// Requires a modifier: a global hotkey bound to a bare key would fire while the
    /// user was typing in any application, which is worse than having no hotkey.
    public static func parse(_ combo: String) throws -> Combination {
        let parts = combo.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw Error.unparseable(combo) }

        let modifierFlags: [String: (UInt32, String)] = [
            "cmd": (UInt32(cmdKey), "\u{2318}"), "command": (UInt32(cmdKey), "\u{2318}"),
            "ctrl": (UInt32(controlKey), "\u{2303}"), "control": (UInt32(controlKey), "\u{2303}"),
            "alt": (UInt32(optionKey), "\u{2325}"), "opt": (UInt32(optionKey), "\u{2325}"),
            "option": (UInt32(optionKey), "\u{2325}"),
            "shift": (UInt32(shiftKey), "\u{21E7}"),
        ]

        // Every part a modifier means there is nothing to press. Distinguishing that
        // from "no modifier" matters: `cmd+` was reported as having no modifier, which
        // is both wrong and unactionable — it has one, and needs a key.
        guard parts.contains(where: { modifierFlags[$0.lowercased()] == nil }) else {
            throw Error.missingKey(combo)
        }

        let keyName = parts[parts.count - 1]
        var modifiers: UInt32 = 0
        var symbols: [String] = []
        for modifier in parts.dropLast() {
            guard let flag = modifierFlags[modifier.lowercased()] else {
                throw Error.unparseable(String(modifier))
            }
            modifiers |= flag.0
            if !symbols.contains(flag.1) { symbols.append(flag.1) }
        }

        // Reachable now. Before, an earlier check rejected every single-part
        // combination, so this read as a guard while guarding nothing.
        guard modifiers != 0 else { throw Error.noModifier(combo) }
        guard let keyCode = KeyMap.code(for: keyName) else { throw Error.unparseable(keyName) }

        return Combination(
            keyCode: UInt32(keyCode),
            carbonModifiers: modifiers,
            display: symbols.joined() + keyName.uppercased()
        )
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: @Sendable () -> Void
    private static let signature = OSType(0x4F43_4C4B)  // 'OCLK'

    /// Registers `combination` system-wide. The registration lives as long as this object.
    public init(_ combination: Combination, onPress: @escaping @Sendable () -> Void) throws {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context else { return noErr }
                var identifier = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard identifier.signature == HotKey.signature else { return noErr }
                Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().onPress()
                return noErr
            },
            1, &eventType, context, &handler
        )

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            combination.keyCode, combination.carbonModifiers,
            identifier, GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr else { throw Error.registrationFailed(status) }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
