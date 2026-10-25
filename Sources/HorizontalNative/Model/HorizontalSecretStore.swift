import Foundation
import Security

/// Where a distributor credential is kept: an item of its own in the
/// keychain, or memory in tests.
struct HorizontalSecretStore: Sendable {
    var read: @Sendable () -> String?
    var write: @Sendable (String?) throws -> Void
    /// Whether a secret is stored, without reading it: on macOS reading a
    /// keychain item can ask the user, looking one up does not.
    var exists: @Sendable () -> Bool

    /// The generic password under `service` and `account`; `noun` names it
    /// in the keychain's refusals ("client secret", "API key").
    static func keychain(service: String, account: String, label: String, noun: String) -> HorizontalSecretStore {
        @Sendable func itemQuery() -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
        }
        return HorizontalSecretStore(
            read: {
                var query = itemQuery()
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            },
            write: { secret in
                // Deleted and added rather than updated, so the item's access
                // belongs to the app writing it.
                let deleted = SecItemDelete(itemQuery() as CFDictionary)
                guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                    throw KeychainError(status: deleted, noun: noun)
                }
                guard let secret, !secret.isEmpty else { return }
                var item = itemQuery()
                item[kSecValueData as String] = Data(secret.utf8)
                item[kSecAttrLabel as String] = label
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else {
                    throw KeychainError(status: added, noun: noun)
                }
            },
            exists: {
                var query = itemQuery()
                query[kSecReturnAttributes as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
            }
        )
    }

    /// A store that keeps the secret in memory, for tests.
    static func memory(_ initial: String? = nil) -> HorizontalSecretStore {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
            init(_ value: String?) { self.value = value }
        }
        let box = Box(initial)
        return HorizontalSecretStore(
            read: { box.lock.withLock { box.value } },
            write: { secret in box.lock.withLock { box.value = secret?.isEmpty == false ? secret : nil } },
            exists: { box.lock.withLock { box.value != nil } }
        )
    }

    struct KeychainError: LocalizedError {
        var status: OSStatus
        var noun: String

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "The keychain refused the \(noun)\(message.map { ": \($0)" } ?? " (\(status))")."
        }
    }
}
