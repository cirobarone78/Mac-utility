import Foundation
import Security

/// Le chiavi API (Anthropic, VirusTotal, Have I Been Pwned) stanno nel Portachiavi di macOS, mai in un file.
enum Keychain {
    static let anthropic = "anthropic-api-key"
    static let virusTotal = "virustotal-api-key"
    static let hibp = "hibp-api-key"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "OmniTools",
         kSecAttrAccount as String: account]
    }

    static func readKey(_ account: String = anthropic) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else {
            // In alternativa, la variabile d'ambiente (comoda quando si avvia da Xcode).
            return account == anthropic ? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] : nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveKey(_ key: String, account: String = anthropic) -> Bool {
        deleteKey(account)
        var item = base(account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(_ account: String = anthropic) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
