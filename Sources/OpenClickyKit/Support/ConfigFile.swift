import Foundation

/// Everything this tool remembers between runs: API keys, and which model to use.
///
/// The one store. There is no Keychain path any more, and that is the point — reading
/// a credential's data there is gated by an ACL naming the binaries allowed to see it,
/// granted *per binary*, and `swift build` produces a new one every time. So every
/// rebuild raised a dialog, and a tool that asks for a password on each run trains its
/// user to click through prompts, which is worse for their security than a file with
/// the right permissions. A second store was also a second thing to audit, a second
/// place a stale key could hide, and a second answer to "where is my key" — the CLI
/// and the app disagreeing about that is how a run signs with a credential nobody
/// chose.
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

    // MARK: - Keys

    /// The stored keys, by provider name. Empty when the file does not exist.
    ///
    /// A missing file is not an error: it is the normal state before anyone runs
    /// `auth`, and reporting it as a failure would bury the real message — that no
    /// credential is configured — under a path that was never expected to exist.
    public func keys() throws -> [String: String] {
        // The gate belongs here and not in `load`, because it is about *using* a
        // secret. Settings are not secret, and a write has to preserve what it did
        // not come to change — see `setKey`.
        try refusePermissiveFile()
        return try load().providers.mapValues(\.apiKey)
    }

    /// Stores one provider's key, leaving the others — and the settings — alone.
    ///
    /// Read-modify-write rather than overwrite: a user with two providers configured
    /// should not lose one by running `auth` for the other.
    ///
    /// Deliberately reads *past* the permission gate. It used to go through `keys()`
    /// with `try?`, so writing a key into a file someone had widened silently threw
    /// away every other key in it — the gate's refusal collapsed to "no keys stored".
    /// Preserving them and rewriting the file `0600` is the recovery; the exposure
    /// already happened, and `keys()` still refuses to *use* what was in it until the
    /// mode is fixed by this write.
    public func setKey(_ key: String, provider: String) throws {
        var stored = (try? load()) ?? Stored()
        stored.providers[provider] = Stored.Entry(apiKey: key)
        try save(stored)
    }

    /// Removes one provider's key. Silent when there was none.
    public func removeKey(provider: String) throws {
        var stored = (try? load()) ?? Stored()
        guard stored.providers.removeValue(forKey: provider) != nil else { return }
        try save(stored)
    }

    // MARK: - Settings

    /// The model choice, kept beside the keys because it is the same question asked
    /// twice: which endpoint answers, and what does it answer as.
    ///
    /// Every field is optional and every one means "the user chose this" — absent is
    /// not the same claim as a default, and storing a default would freeze it: a
    /// config written today would keep pinning today's model after the built-in one
    /// moved on, without anyone having chosen that.
    public struct Settings: Codable, Sendable, Equatable {
        /// A `Provider.Kind` raw value. A string rather than the enum so a file
        /// written by a newer build, naming a provider this one has never heard of,
        /// is ignored rather than rejected — the whole file still decodes.
        public var provider: String?
        public var model: String?
        public var baseURL: String?
        /// A stronger model asked how to approach the task first. Nil runs unplanned.
        public var planner: String?

        public init(
            provider: String? = nil, model: String? = nil,
            baseURL: String? = nil, planner: String? = nil
        ) {
            self.provider = provider.cleaned
            self.model = model.cleaned
            self.baseURL = baseURL.cleaned
            self.planner = planner.cleaned
        }

        public var isEmpty: Bool {
            provider == nil && model == nil && baseURL == nil && planner == nil
        }

        /// Whether a stored model, base URL and planner belong to the provider about
        /// to be used.
        ///
        /// Load-bearing. A model is only meaningful next to the endpoint that serves
        /// it: settings saying `ollama` + `llava` must not hand "llava" to
        /// `--provider anthropic`, which is a 404 that reads as a broken install. A
        /// settings file that names no provider applies to whatever is in play,
        /// because the user expressed no opinion about which.
        public func applies(to providerName: String) -> Bool {
            provider == nil || provider == providerName
        }
    }

    /// The stored settings. Empty when the file does not exist or holds none.
    ///
    /// Not behind the permission gate, unlike `keys()`. A model id is not a secret,
    /// and refusing to read it out of a widened file would break the settings window
    /// at exactly the moment it is needed to fix things — while leaking nothing.
    public func settings() throws -> Settings {
        try load().settings ?? Settings()
    }

    /// Replaces the settings, leaving every stored key alone.
    public func setSettings(_ settings: Settings) throws {
        var stored = (try? load()) ?? Stored()
        stored.settings = settings.isEmpty ? nil : settings
        try save(stored)
    }

    // MARK: - The file itself

    /// The file's contents, with no permission gate. Empty when it does not exist.
    private func load() throws -> Stored {
        guard FileManager.default.fileExists(atPath: url.path) else { return Stored() }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw Error.malformed(path: url.path, detail: "\(error)")
        }
    }

    private func save(_ stored: Stored) throws {
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
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            try data.write(to: url, options: .atomic)
            // Again after the write: `.atomic` replaces the file with a new one, which
            // takes the process umask rather than the mode set a moment ago.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } else {
            guard FileManager.default.createFile(
                atPath: url.path, contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw Error.malformed(path: url.path, detail: "could not be created")
            }
        }
    }

    /// The file's own protection problem, or nil when there is none.
    ///
    /// Asked separately from `keys()` because a *passive* reader has to be able to say
    /// "your key file is exposed" without trying to use the key. The app's settings
    /// panel resolved the provider with `try?` and rendered the failure as "no key
    /// stored" — the one wrong answer, because that state looks unremarkable and the
    /// exposure carries on unmentioned while the CLI shouts about it.
    public func permissionProblem() -> Error? {
        do {
            try refusePermissiveFile()
            return nil
        } catch let error as Error {
            return error
        } catch {
            // Anything else is a stat failure on a file that may not exist, which is
            // not a protection problem and has its own reporting.
            return nil
        }
    }

    /// Throws when anyone but the owner can read the file.
    ///
    /// Checked on every read rather than once at write: the file can be widened after
    /// it is written — by an editor, a backup restore, a `chmod -R` — and the only
    /// moment that matters is the moment the key is about to be used.
    private func refusePermissiveFile() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.posixPermissions] as? NSNumber else { return }
        let mode = number.intValue
        // Any bit set for group or other.
        if mode & 0o077 != 0 {
            throw Error.tooOpen(path: url.path, mode: mode)
        }
    }

    /// The on-disk shape.
    ///
    /// Both sections are optional on read. A file holding only settings — the state
    /// after picking a model for a keyless local Ollama — has to decode, and so does
    /// one written by a build that grows a third section later. Decoding is explicit
    /// for that reason: synthesised `Codable` demands every key it knows about.
    private struct Stored: Codable {
        struct Entry: Codable { let apiKey: String }
        var providers: [String: Entry] = [:]
        var settings: Settings?

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providers = try container.decodeIfPresent(
                [String: Entry].self, forKey: .providers
            ) ?? [:]
            settings = try container.decodeIfPresent(Settings.self, forKey: .settings)
        }
    }
}

private extension Optional where Wrapped == String {
    /// Trimmed, with an empty result read as "not set".
    ///
    /// A settings field cleared in the UI arrives as `""`, and stored verbatim it is
    /// a model id of zero characters — accepted by the resolver, rejected by the
    /// endpoint, and invisible in the file next to the fields that look the same.
    var cleaned: String? {
        guard let text = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
