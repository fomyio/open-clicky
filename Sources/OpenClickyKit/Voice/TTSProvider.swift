import Foundation

/// Which voice speaks a session's replies.
///
/// The counterpart to `VoiceProvider`, and for output rather than input. `SpeechSynthesizer`
/// already names the trade a hosted voice makes — real latency per sentence, and a stop
/// that unwinds a network buffer instead of cutting a device call — so this is a choice
/// the user makes deliberately, not a default this build could safely change under them.
/// `.system` stays the default for exactly that reason: nobody who has never opened
/// Settings should wake up to a slower, less certain barge-in because a hosted voice
/// sounds better.
public enum TTSProvider: String, Sendable, CaseIterable, Identifiable, Equatable {
    /// `AVSpeechSynthesizer`. Starts and stops instantly; sounds like a Mac.
    case system
    /// OpenAI's `gpt-4o-mini-tts`, with a style instruction for warmth rather than a
    /// flat reading. Reuses the model key when there is one — see `sharedCredentialName`.
    case openai

    public var id: String { rawValue }

    public static let `default` = TTSProvider.system

    public var label: String {
        switch self {
        case .system: return "System"
        case .openai: return "OpenAI"
        }
    }

    /// One line on what picking this costs and gains, for the settings window.
    public var detail: String {
        switch self {
        case .system:
            return """
                The built-in macOS voice. Starts the instant a sentence is ready and \
                stops the instant you talk over it — no network round trip either way.
                """
        case .openai:
            return """
                A natural, expressive voice over the network. Each sentence costs a \
                few hundred milliseconds before it starts, and barge-in stops it a beat \
                later than the system voice does.
                """
        }
    }

    /// Whether this vendor needs a key at all. `.system` never asks Settings for one.
    public var needsCredential: Bool {
        switch self {
        case .system: return false
        case .openai: return true
        }
    }

    /// The name this provider's key is stored under in `~/.openclicky/config.json`.
    ///
    /// Not the model provider's own entry, for the reason every dedicated entry in this
    /// project exists: revoking a model key should not silently mute the agent's voice,
    /// and "it stopped talking" is a bad way to learn a key was rotated.
    public var credentialName: String {
        switch self {
        case .system: return ""
        case .openai: return "openai-tts"
        }
    }

    public var apiKeyVariable: String {
        switch self {
        case .system: return ""
        case .openai: return "OPENAI_TTS_API_KEY"
        }
    }

    /// The model provider's own key entry to fall back on, or nil.
    ///
    /// The reason this exists at all: someone who already pasted an OpenAI key for the
    /// model should get a natural voice from one picker click, not a second secret to
    /// paste before the radio button does anything. See `VoiceProvider.sharedCredentialName`,
    /// which this mirrors exactly.
    public var sharedCredentialName: String? {
        switch self {
        case .system: return nil
        case .openai: return Provider.Kind.openai.rawValue
        }
    }

    public var fallbackAPIKeyVariable: String? {
        switch self {
        case .system: return nil
        case .openai: return "OPENAI_API_KEY"
        }
    }

    public var signupHint: String {
        switch self {
        case .system: return ""
        case .openai: return "platform.openai.com/api-keys"
        }
    }

    public var authCommand: String { "openclicky auth --tts \(rawValue)" }

    /// Reads it from a stored settings value, falling back to the default.
    public static func stored(_ settings: ConfigFile.Settings) -> TTSProvider {
        settings.ttsProvider.flatMap(TTSProvider.init(rawValue:)) ?? .default
    }

    /// The key for this provider, environment first, then the file. Nil for `.system`,
    /// which needs none.
    public func storedKey(config: ConfigFile) throws -> String? {
        try resolvedKey(config: config).key
    }

    /// The key and where it came from. See `VoiceProvider.resolvedKey`, which this is
    /// the output half of.
    public func resolvedKey(config: ConfigFile) throws -> (key: String?, source: VoiceProvider.KeySource) {
        guard needsCredential else { return (nil, .none) }
        let environment = ProcessInfo.processInfo.environment
        for variable in [apiKeyVariable, fallbackAPIKeyVariable].compactMap({ $0 }) {
            if let key = environment[variable],
               !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (key, .environment)
            }
        }
        let keys = try config.keys()
        if let key = keys[credentialName] { return (key, .dedicated) }
        if let shared = sharedCredentialName, let key = keys[shared] {
            return (key, .shared(shared))
        }
        return (nil, .none)
    }

    public func keyIsFromEnvironment() -> Bool {
        guard needsCredential else { return false }
        let environment = ProcessInfo.processInfo.environment
        return [apiKeyVariable, fallbackAPIKeyVariable].compactMap { $0 }.contains {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Builds the synthesiser this provider names.
    ///
    /// **Never fails to a missing voice.** `.system` needs nothing and always returns
    /// one; `.openai` returns nil without a key, and the caller's job is to fall back to
    /// `.system` rather than leave a session that cannot speak at all — narration is an
    /// enhancement, and losing it must never cost the ability to hear the agent at all.
    public func synthesizer(
        config: ConfigFile, onFinished: @escaping @Sendable () -> Void
    ) throws -> (any SpeechSynthesizer)? {
        switch self {
        case .system:
            return SystemSpeechSynthesizer(onFinished: onFinished)
        case .openai:
            guard let key = try storedKey(config: config) else { return nil }
            return OpenAISpeechSynthesizer(apiKey: key, onFinished: onFinished)
        }
    }
}
