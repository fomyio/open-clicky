import Testing
import Foundation
@testable import OpenClickyKit

/// The vendor choice, and the credential plumbing that made a voice session impossible
/// to start from the app.
///
/// The defect these are written against: `DeepgramTranscriber.Error.missingCredentials`
/// told the user to run `openclicky auth --provider deepgram`. `--provider` takes a
/// `Provider.Kind`, "deepgram" is not one, and the parser rejected it — so the only
/// remaining route to a voice key was `export DEEPGRAM_API_KEY=...`, which reaches a
/// process launched from a terminal and never one launched from Finder. The app's menu
/// item could not succeed on any machine, and the message explaining why named a command
/// that errored.
@Suite("Voice provider")
struct VoiceProviderTests {

    // MARK: - The message that sent people nowhere

    /// The rule `AnthropicClient.missingCredentials` was already corrected under, now
    /// held structurally: a message that tells someone to run a command must name one
    /// the parser accepts. Derived from the parser rather than compared to a literal,
    /// so renaming the flag breaks this rather than quietly restoring the original bug.
    @Test("The missing-key message names a command the parser accepts", arguments: VoiceProvider.allCases)
    func missingKeyMessageNamesARealCommand(provider: VoiceProvider) throws {
        let message = "\(MissingVoiceCredentials(provider))"
        let command = try #require(
            message.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("openclicky ") },
            "the message offers no command at all"
        )
        let arguments = command.split(separator: " ").dropFirst().map(String.init)
        let parsed = try #require(try? Invocation.parse(arguments).get(),
                                  "`\(command)` does not parse")
        #expect(parsed.command == .auth)
        #expect(parsed.voiceProvider == provider)
    }

    /// The other half of why the app could not be fixed by following the advice: the
    /// fallback it offered works only for a process that inherits a shell.
    @Test("The message says why an exported variable does not reach the app")
    func messageExplainsTheFinderCase() {
        let message = "\(MissingVoiceCredentials(.deepgram))"
        #expect(message.contains("DEEPGRAM_API_KEY"))
        #expect(message.lowercased().contains("finder"))
    }

    /// `DeepgramTranscriber` keeps its own error case, and it must not drift back into
    /// its own wording — that is how the bad command survived a rewrite of the file
    /// around it.
    @Test("Deepgram's own error defers to the shared text")
    func deepgramErrorDefers() {
        #expect(DeepgramTranscriber.Error.missingCredentials.description
            == "\(MissingVoiceCredentials(.deepgram))")
    }

    // MARK: - Credentials

    /// Deliberately distinct, even for OpenAI. A realtime key and a Messages key are
    /// frequently different keys with different scopes; sharing one entry would mean
    /// revoking a model key silently stops voice, which presents as a broken microphone.
    @Test("Each vendor stores under its own entry, and never a model provider's")
    func credentialNamesAreDistinct() {
        let names = VoiceProvider.allCases.map(\.credentialName)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(Provider.Kind(rawValue: name) == nil,
                    "\(name) collides with a model provider's key entry")
        }
    }

    @Test("A stored key is found, and removing it leaves nothing behind")
    func storedKeyRoundTrips() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] == nil)

        #expect(try VoiceProvider.deepgram.storedKey(config: config) == nil)
        try config.setKey("dg-test-123456789", provider: VoiceProvider.deepgram.credentialName)
        #expect(try VoiceProvider.deepgram.storedKey(config: config) == "dg-test-123456789")
        // The other vendor's key is a different entry, not the same one under a label.
        #expect(try VoiceProvider.openaiRealtime.storedKey(config: config) == nil)
    }

    /// The friction this removes: the keys in `config.json` are already the user's
    /// OpenAI credentials, and demanding a second copy under a second name before the
    /// picker will do anything asks them to paste the same secret twice to enable a
    /// radio button.
    @Test("OpenAI Realtime borrows the stored openai key when it has none of its own")
    func realtimeBorrowsTheModelKey() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)
        try #require(ProcessInfo.processInfo.environment["OPENAI_REALTIME_API_KEY"] == nil)

        try config.setKey("sk-test-model-key", provider: Provider.Kind.openai.rawValue)
        let borrowed = try VoiceProvider.openaiRealtime.resolvedKey(config: config)
        #expect(borrowed.key == "sk-test-model-key")
        #expect(borrowed.source == .shared("openai"))

        // Deepgram has nothing to borrow — no other entry could hold a Deepgram key,
        // and reaching for one would sign a Deepgram socket with an OpenAI secret.
        #expect(try VoiceProvider.deepgram.resolvedKey(config: config).key == nil)
        #expect(VoiceProvider.deepgram.sharedCredentialName == nil)
    }

    /// The order is the reason both entries are kept. Someone who wants a separately
    /// scoped, separately revocable realtime key stores one and it wins; someone who
    /// just wants the feature on gets it from the key they already pasted.
    @Test("A dedicated realtime key wins over the borrowed one")
    func dedicatedKeyWins() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)

        try config.setKey("sk-test-model-key", provider: Provider.Kind.openai.rawValue)
        try config.setKey("sk-test-realtime-key",
                          provider: VoiceProvider.openaiRealtime.credentialName)
        let resolved = try VoiceProvider.openaiRealtime.resolvedKey(config: config)
        #expect(resolved.key == "sk-test-realtime-key")
        #expect(resolved.source == .dedicated)
    }

    /// The refusal a world-readable file raises is left to propagate rather than
    /// softened to "no key": a credential in a file other accounts can read is already
    /// exposed, and carrying on would only decide when someone finds out.
    @Test("An exposed config file refuses rather than reporting no key")
    func exposedFileRefuses() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("dg-test-123456789", provider: VoiceProvider.deepgram.credentialName)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )
        #expect(throws: ConfigFile.Error.self) {
            try VoiceProvider.deepgram.storedKey(config: config)
        }
    }

    @Test("No key means no transcriber, rather than one that cannot work")
    func absentKeyYieldsNoTranscriber() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] == nil)
        #expect(try VoiceProvider.deepgram.transcriber(config: config) == nil)
    }

    /// Only reachable now when there is genuinely nothing to use, so it can say so —
    /// and must, or it would send someone to store a key they may already have under
    /// the other name.
    @Test("The missing-key message mentions the entry voice would have borrowed")
    func messageMentionsTheBorrowedEntry() {
        let text = "\(MissingVoiceCredentials(.openaiRealtime))"
        #expect(text.contains("openai"))
        // Deepgram has no such entry, so it must not claim one.
        #expect(!"\(MissingVoiceCredentials(.deepgram))".contains("would otherwise have borrowed"))
    }

    // MARK: - The stored choice

    @Test("An unreadable stored vendor falls back rather than taking voice down")
    func unknownStoredVendorFallsBack() {
        #expect(VoiceProvider.stored(.init()) == .default)
        #expect(VoiceProvider.stored(.init(voiceProvider: "whisper-from-2031")) == .default)
        #expect(VoiceProvider.stored(.init(voiceProvider: "openai-realtime")) == .openaiRealtime)
    }

    /// The choice has to survive a round trip through the file, or the settings window
    /// would show one vendor while a session reached for the other's key.
    @Test("The choice round-trips through the config file")
    func choiceRoundTrips() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setSettings(.init(voiceProvider: VoiceProvider.openaiRealtime.rawValue))
        #expect(VoiceProvider.stored(try config.settings()) == .openaiRealtime)
    }

    /// Unlike `executionMode`, which a widened file must not be allowed to set: choosing
    /// a transcription vendor grants nothing and disables no gate, so dropping it would
    /// take a harmless choice away over an exposure it cannot contribute to.
    @Test("A widened file still yields the vendor choice, unlike the execution mode")
    func vendorSurvivesAWidenedFile() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setSettings(.init(
            executionMode: "auto", voiceProvider: VoiceProvider.openaiRealtime.rawValue
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )
        let settings = try config.settings()
        #expect(settings.executionMode == nil)
        #expect(VoiceProvider.stored(settings) == .openaiRealtime)
    }

    /// "Absent is not the same claim as a default, and storing a default would freeze
    /// it" — `ConfigFile.Settings`' own rule, which the settings window was breaking for
    /// this field. Held here rather than in the app target, which has no tests: a stored
    /// value must still round-trip, and the default must still resolve from nothing.
    @Test("An unchosen vendor resolves from an absent value, not a frozen one")
    func defaultNeedsNoStoredValue() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        // What the settings window writes when the user has expressed no opinion.
        try config.setSettings(.init(provider: "openai", voiceProvider: nil))
        #expect(try config.settings().voiceProvider == nil)
        #expect(VoiceProvider.stored(try config.settings()) == .default)

        // And a real choice is still persisted.
        try config.setSettings(.init(provider: "openai",
                                     voiceProvider: VoiceProvider.openaiRealtime.rawValue))
        #expect(VoiceProvider.stored(try config.settings()) == .openaiRealtime)
    }

    // MARK: - Rates

    /// A vendor told the wrong rate does not fail — it transcribes noise, confidently.
    /// The two wired up disagree, which is why the rate lives on the transcriber rather
    /// than in `AudioFormat`.
    @Test("Each vendor carries the rate it was actually told")
    func ratesMatchWhatEachVendorIsTold() {
        #expect(DeepgramTranscriber(apiKey: "x").sampleRate == AudioFormat.sampleRate)
        #expect(OpenAIRealtimeTranscriber(apiKey: "x").sampleRate == 24_000)

        // Deepgram's rate is not merely stored, it is what the socket declares.
        let url = DeepgramTranscriber.endpoint(base: URL(string: "wss://example.invalid/listen")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "sample_rate" }?.value
            == String(DeepgramTranscriber(apiKey: "x").sampleRate))
    }
}
