import Testing
import Foundation
@testable import OpenClickyKit

/// Keys in a file the user owns.
///
/// The Keychain is the safer store and the wrong one here: its ACL is granted per
/// binary, `swift build` makes a new one every time, and a tool that raises a password
/// dialog on every run teaches its user to click through prompts. The trade is that
/// this is plaintext, so what the code can still guarantee is the file's protection.
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

    @Test("The config file is used before the Keychain")
    func configBeatsKeychain() throws {
        // The point of the change: a key in the file means no dialog, ever.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-from-file-123", provider: "anthropic")

        let keychain = Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
        try keychain.write("sk-ant-from-keychain-123", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        let provider = try Provider.resolve(
            config: config, kind: .anthropic, keychain: keychain, environment: [:]
        )
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
            keychain: Keychain(service: "com.openclicky.tests.\(UUID().uuidString)"),
            environment: ["ANTHROPIC_API_KEY": "sk-ant-from-env-123"]
        )
        if case let .apiKey(k)? = provider.credentials { #expect(k == "sk-ant-from-env-123") }
        else { Issue.record("no api key resolved") }
        #expect(provider.source == Provider.Source.environment)
    }

    @Test("A Keychain key still works when the file has none")
    func keychainRemainsAFallback() throws {
        // Nobody's existing setup breaks because the default store moved.
        let config = scratch()
        let keychain = Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
        try keychain.write("sk-ant-from-keychain-123", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        let provider = try Provider.resolve(
            config: config, kind: .anthropic, keychain: keychain, environment: [:]
        )
        if case let .apiKey(k)? = provider.credentials { #expect(k == "sk-ant-from-keychain-123") }
        else { Issue.record("no api key resolved") }
        #expect(provider.source == Provider.Source.keychain)
    }

    // MARK: - Adopting a key that is already stored

    @Test("A Keychain key is copied into the file, once")
    func adoptsAnExistingKey() throws {
        // Asking someone to find their key a second time is asking them to dig a
        // secret out of wherever they kept it — a worse habit than the dialog this
        // change removes.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        let keychain = Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
        try keychain.write("sk-ant-test-123456789", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        #expect(try config.adopt(
            provider: "anthropic", account: Keychain.apiKeyAccount,
            from: keychain, mayPrompt: true
        ))
        #expect(try config.keys()["anthropic"] == "sk-ant-test-123456789")
        #expect(try mode(of: config.url) & 0o077 == 0, "the copy must be as private as the original")
    }

    @Test("Adoption does not overwrite a key already in the file")
    func adoptionIsNotAnOverwrite() throws {
        // The file is the newer, authoritative store. A stale Keychain entry must not
        // silently replace a key the user just set.
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-ant-current-123", provider: "anthropic")

        let keychain = Keychain(service: "com.openclicky.tests.\(UUID().uuidString)")
        try keychain.write("sk-ant-stale-123", account: Keychain.apiKeyAccount)
        defer { try? keychain.delete(account: Keychain.apiKeyAccount) }

        #expect(try !config.adopt(
            provider: "anthropic", account: Keychain.apiKeyAccount,
            from: keychain, mayPrompt: true
        ))
        #expect(try config.keys()["anthropic"] == "sk-ant-current-123")
    }

    @Test("Adopting nothing reports nothing, rather than claiming a migration")
    func adoptingAnAbsentKeyIsFalse() throws {
        let config = scratch()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        #expect(try !config.adopt(
            provider: "anthropic", account: Keychain.apiKeyAccount,
            from: Keychain(service: "com.openclicky.tests.\(UUID().uuidString)"),
            mayPrompt: false
        ))
        #expect(try config.keys().isEmpty)
    }

}
