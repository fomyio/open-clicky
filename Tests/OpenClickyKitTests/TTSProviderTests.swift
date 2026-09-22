import Testing
import Foundation
@testable import OpenClickyKit

/// The output half of `VoiceProviderTests`: which voice speaks a session's replies, and
/// the credential plumbing that lets picking one cost nothing when the user already has
/// an OpenAI key stored for the model.
@Suite("TTS provider")
struct TTSProviderTests {

    // MARK: - The system voice needs nothing

    @Test("The system voice needs no credential and always synthesises")
    func systemNeedsNoCredential() throws {
        #expect(!TTSProvider.system.needsCredential)
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        #expect(try TTSProvider.system.storedKey(config: config) == nil)
        #expect(try TTSProvider.system.synthesizer(config: config, onFinished: {}) != nil)
    }

    // MARK: - Credentials

    /// Deliberately distinct from the model provider's own entry, for the reason every
    /// dedicated entry in this project exists: revoking a model key must not silently
    /// mute the agent's voice.
    @Test("The OpenAI voice stores under its own entry, not the model provider's")
    func credentialNameIsDistinct() {
        #expect(TTSProvider.openai.credentialName != Provider.Kind.openai.rawValue)
        #expect(Provider.Kind(rawValue: TTSProvider.openai.credentialName) == nil)
    }

    @Test("A stored key is found, and removing it leaves nothing behind")
    func storedKeyRoundTrips() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_TTS_API_KEY"] == nil)
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)

        #expect(try TTSProvider.openai.storedKey(config: config) == nil)
        try config.setKey("sk-test-tts-123456789", provider: TTSProvider.openai.credentialName)
        #expect(try TTSProvider.openai.storedKey(config: config) == "sk-test-tts-123456789")
    }

    /// The friction this removes: the keys in `config.json` are already the user's
    /// OpenAI credentials, and demanding a second copy under a second name before a
    /// natural voice does anything asks them to paste the same secret twice for one
    /// picker click.
    @Test("The OpenAI voice borrows the stored model key when it has none of its own")
    func openaiBorrowsTheModelKey() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)
        try #require(ProcessInfo.processInfo.environment["OPENAI_TTS_API_KEY"] == nil)

        try config.setKey("sk-test-model-key", provider: Provider.Kind.openai.rawValue)
        let borrowed = try TTSProvider.openai.resolvedKey(config: config)
        #expect(borrowed.key == "sk-test-model-key")
        #expect(borrowed.source == .shared("openai"))
    }

    @Test("A dedicated TTS key wins over the borrowed one")
    func dedicatedKeyWins() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)

        try config.setKey("sk-test-model-key", provider: Provider.Kind.openai.rawValue)
        try config.setKey("sk-test-dedicated-tts", provider: TTSProvider.openai.credentialName)
        let resolved = try TTSProvider.openai.resolvedKey(config: config)
        #expect(resolved.key == "sk-test-dedicated-tts")
        #expect(resolved.source == .dedicated)
    }

    @Test("An exposed config file refuses rather than reporting no key")
    func exposedFileRefuses() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-test-tts", provider: TTSProvider.openai.credentialName)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )
        #expect(throws: ConfigFile.Error.self) {
            try TTSProvider.openai.storedKey(config: config)
        }
    }

    // MARK: - Falling back rather than failing

    @Test("No key means no OpenAI synthesiser, rather than one that cannot work")
    func absentKeyYieldsNoSynthesizer() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil)
        try #require(ProcessInfo.processInfo.environment["OPENAI_TTS_API_KEY"] == nil)
        #expect(try TTSProvider.openai.synthesizer(config: config, onFinished: {}) == nil)
    }

    @Test("A stored key does yield a synthesiser")
    func storedKeyYieldsSynthesizer() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-test-tts", provider: TTSProvider.openai.credentialName)
        #expect(try TTSProvider.openai.synthesizer(config: config, onFinished: {}) != nil)
    }

    // MARK: - The stored choice

    @Test("An unreadable stored voice falls back rather than taking narration down")
    func unknownStoredVoiceFallsBack() {
        #expect(TTSProvider.stored(.init()) == .default)
        #expect(TTSProvider.stored(.init(ttsProvider: "hal-9000")) == .default)
        #expect(TTSProvider.stored(.init(ttsProvider: "openai")) == .openai)
    }

    @Test("The default is the system voice, never a network one nobody chose")
    func defaultIsSystem() {
        #expect(TTSProvider.default == .system)
    }

    @Test("The choice round-trips through the config file")
    func choiceRoundTrips() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setSettings(.init(ttsProvider: TTSProvider.openai.rawValue))
        #expect(TTSProvider.stored(try config.settings()) == .openai)
    }

    /// "Absent is not the same claim as a default, and storing a default would freeze
    /// it" — the same rule `voiceProvider` follows in `ConfigFile.Settings`.
    @Test("An unchosen voice resolves from an absent value, not a frozen one")
    func defaultNeedsNoStoredValue() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(.init(provider: "openai", ttsProvider: nil))
        #expect(try config.settings().ttsProvider == nil)
        #expect(TTSProvider.stored(try config.settings()) == .default)

        try config.setSettings(.init(provider: "openai", ttsProvider: TTSProvider.openai.rawValue))
        #expect(TTSProvider.stored(try config.settings()) == .openai)
    }
}
