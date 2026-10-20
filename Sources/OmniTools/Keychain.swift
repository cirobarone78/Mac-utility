import Foundation
import Security

/// La chiave API di Anthropic sta nel Portachiavi di macOS, mai in un file.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "OmniTools",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func readKey() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else {
            // In alternativa, la variabile d'ambiente (comoda quando si avvia da Xcode).
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        deleteKey()
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey() {
        SecItemDelete(base as CFDictionary)
    }
}
