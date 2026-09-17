import Foundation

/// Which vendor turns speech into text for a voice session.
///
/// A choice, not a constant, and the reason is the bug that made this file necessary.
/// `DeepgramTranscriber.Error.missingCredentials` told the user to run
/// `openclicky auth --provider deepgram` — a command that could not work, because
/// `--provider` takes a `Provider.Kind` and "deepgram" is not one. So the *only* way to
/// give a voice session a key was to export `DEEPGRAM_API_KEY`, and the app is launched
/// from Finder, which inherits no shell environment at all. Starting a voice session in
/// OpenClicky.app could therefore never succeed on any machine, and the message that
/// said so sent people to a command that errored.
///
/// The seam `SpeechTranscriber` already describes is what makes a second vendor cheap:
/// the session above it knows three events and nothing about who produced them. What
/// this type adds is the part that was missing either way — a name to store a key
/// under, a variable to read it from, and a place for the settings window to put the
/// choice in front of someone.
public enum VoiceProvider: String, Sendable, CaseIterable, Identifiable, Equatable {
    case deepgram
    case openaiRealtime = "openai-realtime"

    public var id: String { rawValue }

    /// The default when nobody has chosen.
    ///
    /// Deepgram, because it is the one whose interim/final split and VAD events barge-in
    /// was built on — see `VoiceSession`. OpenAI's realtime transcription reports turns
    /// rather than a running guess at one, which is a slightly coarser fit for the same
    /// state machine.
    public static let `default` = VoiceProvider.deepgram

    public var label: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openaiRealtime: return "OpenAI Realtime"
        }
    }

    /// One line on what picking this costs and gains, for the settings window.
    public var detail: String {
        switch self {
        case .deepgram:
            return """
                Streaming transcription over a websocket, with voice-activity events. \
                The fastest of the two to interrupt: barge-in fires on detected speech \
                rather than on a recognised word.
                """
        case .openaiRealtime:
            return """
                The Realtime API in transcription mode, with server-side turn \
                detection. Worth picking if you already have an OpenAI key — it is the \
                same credential the model uses, stored separately so revoking one does \
                not silently break the other.
                """
        }
    }

    /// The name this provider's key is stored under in `~/.openclicky/config.json`.
    ///
    /// Deliberately not the same entry as the model provider's, even for OpenAI. A
    /// realtime key and a Messages key are frequently different keys with different
    /// scopes, and sharing one entry would mean revoking a model key silently stops
    /// voice — a failure that presents as "the microphone broke".
    public var credentialName: String {
        switch self {
        case .deepgram: return "deepgram"
        case .openaiRealtime: return "openai-realtime"
        }
    }

    /// The environment variable checked before the file, in the order every other
    /// credential in this project is resolved.
    public var apiKeyVariable: String {
        switch self {
        case .deepgram: return "DEEPGRAM_API_KEY"
        case .openaiRealtime: return "OPENAI_REALTIME_API_KEY"
        }
    }

    /// The model provider's own key entry to fall back on, or nil.
    ///
    /// Only OpenAI has one, and it is the difference between a vendor you can pick and
    /// a vendor you have to set up. The keys in `~/.openclicky/config.json` are already
    /// the user's OpenAI credentials; demanding a *second* copy under a second name
    /// before the picker will do anything is asking them to paste the same secret twice
    /// to enable a radio button.
    ///
    /// A dedicated `openai-realtime` entry still wins when one exists, and that order is
    /// the whole reason both are kept: someone who wants a separately-scoped, separately
    /// revocable realtime key can store one and it takes precedence, while someone who
    /// just wants the feature on gets it from the key they already pasted. Deepgram has
    /// no such entry to borrow — nothing else in the file could hold a Deepgram key.
    public var sharedCredentialName: String? {
        switch self {
        case .deepgram: return nil
        case .openaiRealtime: return Provider.Kind.openai.rawValue
        }
    }

    /// A second variable to fall back on, or nil.
    ///
    /// Only OpenAI has one: `OPENAI_API_KEY` is already exported on most machines that
    /// would pick this, and refusing to look at it would ask the user to set a second
    /// variable holding the same secret. Deepgram gets no such fallback because there
    /// is no other variable that could plausibly hold a Deepgram key.
    public var fallbackAPIKeyVariable: String? {
        switch self {
        case .deepgram: return nil
        case .openaiRealtime: return "OPENAI_API_KEY"
        }
    }

    /// Where to get a key, named in the error that says one is missing.
    public var signupHint: String {
        switch self {
        case .deepgram: return "console.deepgram.com"
        case .openaiRealtime: return "platform.openai.com/api-keys"
        }
    }

    /// The command that stores one.
    public var authCommand: String { "openclicky auth --voice \(rawValue)" }

    /// Reads it from a stored settings value, falling back to the default.
    ///
    /// A string in the file for the same reason `provider` and `executionMode` are: a
    /// config written by a newer build naming a vendor this one has never heard of has
    /// to leave the rest of the file readable.
    public static func stored(_ settings: ConfigFile.Settings) -> VoiceProvider {
        settings.voiceProvider.flatMap(VoiceProvider.init(rawValue:)) ?? .default
    }

    /// The key for this provider, environment first, then the file.
    ///
    /// The refusal `keys()` raises on a world-readable file is left to propagate rather
    /// than softened to "no key": a credential in a file other accounts can read is
    /// already exposed, and carrying on would only decide when someone finds out.
    public func storedKey(config: ConfigFile) throws -> String? {
        try resolvedKey(config: config).key
    }

    /// The key and where it came from.
    ///
    /// The source is not decoration: "a key is configured" does not tell someone chasing
    /// a stale credential *which* of three places to edit, and for the shared case it is
    /// the difference between "voice has its own key" and "voice is riding on your model
    /// key, so revoking that stops both".
    public func resolvedKey(config: ConfigFile) throws -> (key: String?, source: KeySource) {
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

    /// Which store answered.
    public enum KeySource: Sendable, Equatable {
        case none
        case environment
        /// This vendor's own entry in the config file.
        case dedicated
        /// The model provider's entry, borrowed. Carries the name it was read from.
        case shared(String)
    }

    /// Whether the key came from the environment rather than the file.
    ///
    /// Asked separately so the settings window can say *which* store answered. Someone
    /// chasing a stale key needs to know which of the two to edit, and "a key is
    /// configured" does not tell them.
    public func keyIsFromEnvironment() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return [apiKeyVariable, fallbackAPIKeyVariable].compactMap { $0 }.contains {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Builds the transcriber this provider names, or nil when no key is stored.
    ///
    /// The one place that maps a choice onto a client, so `VoiceController` holds no
    /// opinion about vendors at all — which is what the `SpeechTranscriber` protocol
    /// was for and what the previous version, with `DeepgramTranscriber` named directly
    /// in the app layer, gave up.
    public func transcriber(config: ConfigFile) throws -> (any SpeechTranscriber)? {
        guard let key = try storedKey(config: config) else { return nil }
        switch self {
        case .deepgram: return DeepgramTranscriber(apiKey: key)
        case .openaiRealtime: return OpenAIRealtimeTranscriber(apiKey: key)
        }
    }
}

/// No key for the chosen voice vendor.
///
/// One error for both, phrased per provider. It replaces
/// `DeepgramTranscriber.Error.missingCredentials`, whose text named a command that did
/// not exist — the whole reason voice could not be started from the app.
public struct MissingVoiceCredentials: Error, Equatable, CustomStringConvertible {
    public let provider: VoiceProvider
    public init(_ provider: VoiceProvider) { self.provider = provider }

    public var description: String {
        """
        No \(provider.label) API key found, so a voice session has nothing to \
        transcribe with.

        \(provider.sharedCredentialName.map {
            "No \($0) key is stored either, which voice would otherwise have borrowed.\n\n"
        } ?? "")Store one in \(ConfigFile.defaultURL.path) (get a key at \(provider.signupHint)):
          \(provider.authCommand)

        Or set it for this shell only:
          export \(provider.apiKeyVariable)=...

        The app is launched from Finder and inherits no shell environment, so the \
        stored key — or the Voice section of Settings — is the route that works there.
        """
    }
}
