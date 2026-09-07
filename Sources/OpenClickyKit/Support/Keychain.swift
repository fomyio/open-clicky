import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the Anthropic API key.
///
/// Secrets live here rather than in a config file or the process environment so
/// they are never captured in a transcript, a screenshot, or a crash log.
public struct Keychain: Sendable {

    public static let apiKeyAccount = "anthropic-api-key"
    /// The service every stored credential lives under.
    ///
    /// Named, because `auth` printed it as a literal in its success message: if the
    /// service ever changed, the message would confidently name the wrong one and
    /// send someone looking in the wrong place in Keychain Access.
    public static let serviceName = "com.openclicky.credentials"

    public static let standard = Keychain(service: serviceName)

    public enum Error: Swift.Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        /// The item exists, and macOS wants a human to approve reading it.
        case needsApproval(account: String)

        public var description: String {
            if case let .needsApproval(account) = self {
                return """
                    The Keychain has \(account) but macOS needs you to approve this \
                    copy of openclicky before it can be read. The approval is granted \
                    to one binary, and `swift build` produces a new one each time, so \
                    a rebuild asks again. Run `openclicky doctor` directly in a \
                    terminal and choose Always Allow.
                    """
            }
            let message = SecCopyErrorMessageString(
                { if case let .unexpectedStatus(s) = self { return s }; return noErr }(), nil
            ) as String? ?? "unknown"
            return "Keychain error: \(message)"
        }
    }

    public let service: String

    public init(service: String) { self.service = service }

    /// The accessibility class a stored secret carries, or `nil` when the keychain
    /// does not record one.
    ///
    /// The legacy login keychain — the only one available without an entitlement —
    /// accepts `kSecAttrAccessible` on write and stores nothing, so this returns
    /// `nil`. Kept so that the gap is asserted rather than assumed: if the tool ever
    /// gains the entitlement, the test below will start seeing a value and can be
    /// tightened to require the right one.
    func accessibility(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        return (item as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    /// - Parameters:
    ///   - mayPrompt: whether macOS is allowed to put an approval dialog on screen.
    ///     True where a human is at the terminal to answer it.
    ///   - timeout: how long an unattended read waits before concluding that a dialog
    ///     it cannot see is in the way.
    ///
    /// Reading a credential's *data* is gated by an ACL naming the binaries allowed to
    /// see it, granted per binary — `swift build` produces a new one every time, so a
    /// rebuild asks again. When nobody can answer, `SecItemCopyMatching` neither fails
    /// nor times out: it blocks for as long as the process lives. `doctor` piped to a
    /// file printed two lines and then nothing, indefinitely.
    ///
    /// `LAContext.interactionNotAllowed` does not help — measured, not assumed: it
    /// governs biometric and passcode prompts, not the classic ACL dialog, and the
    /// read blocks with the flag set exactly as it does without it. So the wait is
    /// bounded here instead.
    ///
    /// The worker thread stays blocked until the dialog is answered or the process
    /// exits. That is a leak, and an acceptable one only because this is a
    /// short-lived CLI: the alternative is a command that never returns. It would not
    /// be acceptable in a daemon, and this comment is where the next person finds
    /// that out.
    public func read(
        account: String, mayPrompt: Bool = true, timeout: Duration = .seconds(3)
    ) throws -> String? {
        try read(account: account, mayPrompt: mayPrompt, timeout: timeout, perform: readData)
    }

    /// - Parameter perform: the blocking read itself.
    ///
    /// A seam, because the behaviour worth defending is what happens when that read
    /// *never returns* — and a test cannot create a keychain item it is forbidden to
    /// read, since it would have to be the one that wrote it. The sweep called this
    /// guard NOT CAUGHT until the blocking half could be supplied by the test.
    func read(
        account: String,
        mayPrompt: Bool,
        timeout: Duration,
        perform: @escaping @Sendable (String) throws -> String?
    ) throws -> String? {
        guard !mayPrompt else { return try perform(account) }

        // Asked *before* the read, not after it times out. Attributes never prompt on
        // their own — but once a dialog is pending for this item, securityd blocks
        // every further query about it, so the obvious "time out, then ask whether it
        // exists" ordering hangs on the second question instead of the first.
        let present = (try? exists(account: account)) == true

        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            box.finish(Result { try perform(account) })
        }
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        guard let outcome = box.wait(seconds: seconds) else {
            // Nothing came back in time. The two reasons a credential is unavailable
            // need opposite actions — an absent one means `auth`, a present one means
            // approving this binary — and `present` was settled before the dialog
            // could get in the way.
            if present { throw Error.needsApproval(account: account) }
            return nil
        }
        return try outcome.get()
    }

    /// The blocking read, exactly as it always was.
    private func readData(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        // Both mean the same thing to a caller: a human was needed and did not
        // answer. `errSecUserCanceled` is what an unattended run actually gets — the
        // dialog is raised and dismissed for it — and reporting that verbatim tells
        // the user they cancelled something they never saw.
        if status == errSecInteractionNotAllowed || status == errSecUserCanceled {
            throw Error.needsApproval(account: account)
        }
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a credential is stored, without reading it.
    ///
    /// Attributes are not behind the ACL, so this answers instantly and never prompts
    /// — which is what lets an unattended read distinguish "absent" from "present but
    /// unreadable" rather than reporting both as missing.
    public func exists(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        return true
    }

    public func write(_ value: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        // Requested, but not in effect — and worth saying so plainly.
        //
        // `kSecAttrAccessible` only applies in the data-protection keychain, which
        // needs a keychain-access-group entitlement. A SwiftPM binary does not have
        // one, and adding it to the signed app would put the app and the CLI in
        // different keychains, so `openclicky auth` would store a key the app could
        // not find. Consistency between the two is worth more than an accessibility
        // class neither can currently obtain.
        //
        // Practically: the key lives in the login keychain, which means it can travel
        // in an encrypted backup or a Migration Assistant transfer. It is still
        // protected by the login keychain itself.
        //
        // This was written as though it applied, and nothing checked — the attribute
        // is accepted on write and silently dropped. Found by reading it back.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }
}

/// Carries a blocking read's result back to a bounded waiter.
///
/// A semaphore rather than a `Task`: `SecItemCopyMatching` blocks an OS thread, and a
/// blocked thread inside the cooperative pool is a thread the rest of the program
/// cannot have back.
private final class ResultBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<String?, Swift.Error>?

    func finish(_ value: Result<String?, Swift.Error>) {
        lock.lock(); result = value; lock.unlock()
        semaphore.signal()
    }

    /// The result, or nil if it did not arrive in time.
    func wait(seconds: Double) -> Result<String?, Swift.Error>? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
