import Testing
import Foundation
@testable import OpenClickyKit

/// Keys in a file the user owns.
///
/// The only store. The Keychain was the safer one and the wrong one here: its ACL is
/// granted per binary, `swift build` makes a new one every time, and a tool that
/// raises a password dialog on every run teaches its user to click through prompts.
/// The trade is that this is plaintext, so what the code can still guarantee is the
/// file's protection — and that a write never loses what it did not come to change.
@Suite("Config file")
struct ConfigFileTests {

    private func scratch() -> ConfigFile {
        ConfigFile(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openclicky-\(UUID().uuidString)")
            .appendingPathComponent("config.json"))
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    @Test("A key round-trips")
    func storesAndReads() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")
    }

    @Test("The file is created readable only by its owner")
    func writtenPrivate() throws {
        // Set at creation rather than chmod'ed afterwards: between the two there is a
        // window where the key is on disk and world-readable, and a window is all
        // anyone needs.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        #expect(try mode(of: config.url) & 0o077 == 0, "group or other can read it")
    }

    @Test("A file anyone can read is refused, not used")
    func refusesPermissiveFile() throws {
        // A key in a world-readable file is already exposed; reading it anyway would
        // only decide when someone finds out.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )
        #expect(throws: ConfigFile.Error.self) { _ = try config.keys() }
    }

    @Test("The refusal names the file, the mode and the remedy")
    func refusalIsActionable() {
        let message = ConfigFile.Error
            .tooOpen(path: "/tmp/config.json", mode: 0o644).description
        #expect(message.contains("/tmp/config.json"))
        #expect(message.contains("644"))
        #expect(message.contains("chmod 600"))
        // Rotation matters more than the chmod: the key was exposed while it sat there.
        #expect(message.contains("rotate"))
    }

    @Test("A missing file is empty, not an error")
    func absentFileIsNotAFailure() throws {
        // The normal state before anyone runs `auth`. Reporting it as a failure would
        // bury "no credential is configured" under a path nobody expected to exist.
        #expect(try scratch().keys().isEmpty)
    }

    @Test("Storing one provider leaves the others alone")
    func setKeyIsNotOverwrite() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try config.setKey("sk-openai-test-123456789", provider: "openai")
        let keys = try config.keys()
        #expect(keys["anthropic"] == "sk-ant-test-123456789")
        #expect(keys["openai"] == "sk-openai-test-123456789")
    }

    @Test("Removing one key keeps the rest, and removing nothing is silent")
    func removeKeyIsSurgical() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("a", provider: "anthropic")
        try config.setKey("b", provider: "openai")
        try config.removeKey(provider: "anthropic")
        #expect(try config.keys()["anthropic"] == nil)
        #expect(try config.keys()["openai"] == "b")
        try config.removeKey(provider: "groq")   // never stored
        #expect(try config.keys()["openai"] == "b")
    }

    @Test("Malformed JSON says which file and why")
    func malformedFileIsExplained() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: config.url.path, contents: Data("{ not json".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        #expect(throws: ConfigFile.Error.self) { _ = try config.keys() }
    }

    @Test("An empty file reads as no keys rather than as damage")
    func emptyFileIsEmpty() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: config.url.path, contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        #expect(try config.keys().isEmpty)
    }

    // MARK: - Resolution order

    @Test("The config file is used when nothing is exported")
    func configFileAnswers() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file-123", provider: "anthropic")

        let provider = try Provider.resolve(config: config, kind: .anthropic, environment: [:])
        if case let .apiKey(k)? = provider.credentials { #expect(k == "sk-ant-from-file-123") }
        else { Issue.record("no api key resolved") }
        #expect(provider.source == Provider.Source.configFile)
    }

    @Test("The environment still beats the config file")
    func environmentBeatsConfig() throws {
        // One variable has to be able to override everything, for a one-off run.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file-123", provider: "anthropic")

        let provider = try Provider.resolve(
            config: config, kind: .anthropic,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-from-env-123"]
        )
        if case let .apiKey(k)? = provider.credentials { #expect(k == "sk-ant-from-env-123") }
        else { Issue.record("no api key resolved") }
        #expect(provider.source == Provider.Source.environment)
    }

    // MARK: - A write must not lose what it did not come to change

    @Test("Storing one provider's key leaves the others alone")
    func writesArePerProvider() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try config.setKey("openai-key-123", provider: "openai")

        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")
        #expect(try config.keys()["openai"] == "openai-key-123")

        try config.removeKey(provider: "openai")
        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")
        #expect(try config.keys()["openai"] == nil)
    }

    @Test("Storing a key into a widened file preserves the other keys")
    func writeThroughAWidenedFileKeepsKeys() throws {
        // This used to read through the permission gate with `try?`, so the refusal
        // collapsed to "no keys stored" and the write erased every other provider's
        // key. The exposure is real and already happened; silently destroying the
        // rest of the file on top of it is not a remedy.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )

        try config.setKey("openai-key-123", provider: "openai")

        #expect(try mode(of: config.url) & 0o077 == 0, "the write must also tighten it")
        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")
        #expect(try config.keys()["openai"] == "openai-key-123")
    }

    // MARK: - The model choice lives beside the keys

    @Test("Settings round-trip")
    func settingsRoundTrip() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(
            provider: "openai", model: "gpt-4o", planner: "gpt-5"
        ))
        let stored = try config.settings()
        #expect(stored.provider == "openai")
        #expect(stored.model == "gpt-4o")
        #expect(stored.planner == "gpt-5")
        #expect(stored.baseURL == nil, "an absent field must not become an empty one")
    }

    @Test("Settings and keys do not overwrite each other")
    func settingsAndKeysCoexist() throws {
        // Two writers, one file. Either one clobbering the other is a user losing a
        // key by changing a model, or a model choice by running `auth`.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try config.setSettings(ConfigFile.Settings(provider: "anthropic", model: "claude-opus-5"))
        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")

        try config.setKey("openai-key-123", provider: "openai")
        #expect(try config.settings().model == "claude-opus-5")
    }

    @Test("A blank field is stored as absent, not as an empty string")
    func blankFieldsAreCleared() throws {
        // A planner cleared in the UI arrives as "". Stored verbatim it is a model id
        // of zero characters: accepted by the resolver, rejected by the endpoint, and
        // indistinguishable in the file from the fields that look the same.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }

        try config.setSettings(ConfigFile.Settings(
            provider: "ollama", model: "  llava  ", planner: "   "
        ))
        #expect(try config.settings().model == "llava", "and trimmed")
        #expect(try config.settings().planner == nil)
    }

    @Test("A file holding only settings still decodes")
    func settingsOnlyFileDecodes() throws {
        // The state after choosing a model for a keyless local Ollama. Synthesised
        // Codable would demand a `providers` key that was never written.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"settings":{"provider":"ollama","model":"llava"}}"#.utf8)
            .write(to: config.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: config.url.path
        )

        #expect(try config.settings().model == "llava")
        #expect(try config.keys().isEmpty)
    }

    @Test("A file written before settings existed still reads")
    func keysOnlyFileDecodes() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"providers":{"anthropic":{"apiKey":"sk-ant-old-123"}}}"#.utf8)
            .write(to: config.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: config.url.path
        )

        #expect(try config.keys()["anthropic"] == "sk-ant-old-123")
        #expect(try config.settings().isEmpty)
    }

    /// A model id is not a secret, and refusing to read it out of a widened file would
    /// break the settings window at exactly the moment it is needed to fix things.
    @Test("Settings are readable from a file whose keys are refused")
    func settingsAreNotBehindThePermissionGate() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setSettings(ConfigFile.Settings(provider: "ollama", model: "llava"))
        try config.setKey("sk-ant-test-123456789", provider: "anthropic")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )

        #expect(throws: ConfigFile.Error.self) { _ = try config.keys() }
        #expect(try config.settings().model == "llava")
    }

    // MARK: - Messages that were confidently wrong

    @Test("The article agrees with the provider name", arguments: [
        // "An Anthropic", "An OpenAI", "An Ollama" — all vowel-initial labels.
        (Provider.Kind.openai, "An"), (.ollama, "An"), (.anthropic, "An"),
        (.litellm, "A"), (.groq, "A"),
    ])
    func articleAgreesWithTheLabel(scenario: (Provider.Kind, String)) {
        // "A OpenAI key is already stored" reads as a typo in the one message whose
        // job is to be trusted with a secret — the same defect as "1 turns".
        #expect(scenario.0.article == scenario.1, "\(scenario.0.label)")
    }

    @Test("Asking whether a key is stored never returns the secret")
    func existenceIsAnswerableWithoutExposingIt() throws {
        // What lets `auth` and the settings panel ask honestly. Offering first and
        // checking afterwards produced "An OpenAI key is stored… Nothing was stored
        // for OpenAI" in the same breath.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        #expect(try config.keys()["openai"] == nil)
        try config.setKey("openai-key-123", provider: "openai")
        #expect(try config.keys()["openai"] != nil)
    }

}
