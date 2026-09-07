import Foundation

/// API keys kept in a file the user owns, rather than the Keychain.
///
/// The Keychain is the safer store and the wrong one for this tool. Reading a
/// credential's data is gated by an ACL naming the binaries allowed to see it,
/// granted *per binary* — and `swift build` produces a new one every time, so every
/// rebuild raises a dialog. A tool that asks for a password on each run trains its
/// user to click through prompts, which is worse for their security than a file with
/// the right permissions.
///
/// The trade is real and not hidden: this is plaintext, so anything that can read the
/// home directory can read the key, where the Keychain required an explicit approval.
/// What is defensible is making the file's protection a property of the code rather
/// than of whoever created it — written `0600`, and *refused* when it is readable by
/// anyone else, because a key in a world-readable file is already compromised and
/// carrying on would only decide when someone finds out.
public struct ConfigFile: Sendable {

    /// `~/.openclicky/config.json`, beside the sessions directory.
    ///
    /// Not `~/.config`: the transcripts already live in `~/.openclicky`, and one
    /// directory a user can delete to remove every trace of this tool is worth more
    /// than following a convention only half the tool follows.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclicky/config.json", isDirectory: false)
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case tooOpen(path: String, mode: Int)
        case malformed(path: String, detail: String)

        public var description: String {
            switch self {
            case let .tooOpen(path, mode):
                return """
                    \(path) is mode \(String(format: "%03o", mode)) — readable by \
                    other accounts on this machine, and every local account is in \
                    `staff`, which can traverse a default home directory. Refusing to \
                    read a key from it. Run `chmod 600 \(path)`, and treat the key as \
                    exposed: rotate it.
                    """
            case let .malformed(path, detail):
                return "\(path) is not valid JSON: \(detail)"
            }
        }
    }

    public let url: URL
    public init(url: URL = ConfigFile.defaultURL) { self.url = url }

    /// The stored keys, by provider name. Empty when the file does not exist.
    ///
    /// A missing file is not an error: it is the normal state before anyone runs
    /// `auth`, and reporting it as a failure would bury the real message — that no
    /// credential is configured — under a path that was never expected to exist.
    public func keys() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        try refusePermissiveFile()

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        do {
            let decoded = try JSONDecoder().decode(Stored.self, from: data)
            return decoded.providers.mapValues(\.apiKey)
        } catch {
            throw Error.malformed(path: url.path, detail: "\(error)")
        }
    }

    /// Stores one provider's key, leaving the others alone.
    ///
    /// Read-modify-write rather than overwrite: a user with two providers configured
    /// should not lose one by running `auth` for the other.
    public func setKey(_ key: String, provider: String) throws {
        var providers = (try? keys()) ?? [:]
        providers[provider] = key
        let stored = Stored(providers: providers.mapValues(Stored.Entry.init(apiKey:)))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Written through `createFile` with the mode set at creation, not chmod'ed
        // afterwards: between the two there is a window where the key is on disk and
        // world-readable, and a window is all anyone needs.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            guard FileManager.default.createFile(
                atPath: url.path, contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw Error.malformed(path: url.path, detail: "could not be created")
            }
        }
    }

    /// Removes one provider's key. Silent when there was none.
    public func removeKey(provider: String) throws {
        var providers = (try? keys()) ?? [:]
        guard providers.removeValue(forKey: provider) != nil else { return }
        let stored = Stored(providers: providers.mapValues(Stored.Entry.init(apiKey:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Copies a key out of the Keychain into the file, once.
    ///
    /// The reason this exists rather than "run `auth` again": the key is already
    /// stored, and asking someone to go and find it a second time is asking them to
    /// dig a secret out of wherever they kept it — a worse habit than the dialog this
    /// change is trying to remove. One approval, then never again.
    ///
    /// Returns false when there was nothing to move, so a caller can stay quiet
    /// instead of reporting a migration that did not happen.
    @discardableResult
    public func adopt(
        provider: String, account: String, from keychain: Keychain, mayPrompt: Bool
    ) throws -> Bool {
        guard (try? keys()[provider]) == nil else { return false }
        guard let stored = try keychain.read(account: account, mayPrompt: mayPrompt),
              !stored.isEmpty
        else { return false }
        try setKey(stored, provider: provider)
        return true
    }

    /// Throws when anyone but the owner can read the file.
    ///
    /// Checked on every read rather than once at write: the file can be widened after
    /// it is written — by an editor, a backup restore, a `chmod -R` — and the only
    /// moment that matters is the moment the key is about to be used.
    private func refusePermissiveFile() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else { return }
        let mode = number.intValue
        // Any bit set for group or other.
        if mode & 0o077 != 0 {
            throw Error.tooOpen(path: url.path, mode: mode)
        }
    }

    /// The on-disk shape. Nested under `providers` so the file has somewhere to grow
    /// — a base URL, a default model — without a migration.
    private struct Stored: Codable {
        struct Entry: Codable { let apiKey: String }
        var providers: [String: Entry]
    }
}
