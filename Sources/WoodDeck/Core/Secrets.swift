import Foundation
import Security

// 手动填写的 API 密钥保存在系统钥匙串，不写入设置文件
@MainActor
final class SecretStore {
    static let shared = SecretStore()

    private let service = "WoodDeck.Secret"

    private init() {}

    private func account(_ entry: AppEntry, extra: String = "") -> String {
        extra.isEmpty ? entry.instanceID.uuidString : "\(entry.instanceID.uuidString).\(extra)"
    }

    func secret(for entry: AppEntry) -> String? {
        read(account(entry))
    }

    func setSecret(_ value: String, for entry: AppEntry) {
        if value.isEmpty {
            delete(account(entry))
        } else {
            write(value, account: account(entry))
        }
    }

    func deleteSecret(for entry: AppEntry) {
        delete(account(entry))
    }

    private func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
