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
        public var description: String {
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

    public func read(account: String) throws -> String? {
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
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
