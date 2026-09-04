import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the Anthropic API key.
///
/// Secrets live here rather than in a config file or the process environment so
/// they are never captured in a transcript, a screenshot, or a crash log.
public struct Keychain: Sendable {
    public static let apiKeyAccount = "anthropic-api-key"
    public static let standard = Keychain(service: "com.openclicky.credentials")

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
        // ThisDeviceOnly keeps the key out of encrypted backups and Migration
        // Assistant transfers; a CLI has no need for it to follow the user's account.
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
