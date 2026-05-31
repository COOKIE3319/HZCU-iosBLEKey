import Foundation
import Security

final class StorageService {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let config = "hzcu.config"
        static let keys = "hzcu.keys"
        static let activeKey = "hzcu.activeKey"
        static let lockState = "hzcu.lockState"
    }

    func loadConfig() -> LockConfig {
        guard let data = defaults.data(forKey: Keys.config),
              let cfg = try? JSONDecoder().decode(LockConfig.self, from: data) else {
            return LockConfig()
        }
        return cfg
    }

    func saveConfig(_ config: LockConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Keys.config)
    }

    func loadKeys() -> [KeyProfile] {
        guard let data = defaults.data(forKey: Keys.keys),
              let keys = try? JSONDecoder().decode([KeyProfile].self, from: data) else {
            return []
        }

        return keys.map { key in
            var mutable = key
            mutable.cookie = loadCookie(for: key.keyID) ?? key.cookie
            return mutable
        }
    }

    func saveKeys(_ keys: [KeyProfile]) {
        let sanitized: [KeyProfile] = keys.map { key in
            saveCookie(key.cookie, for: key.keyID)
            var clean = key
            clean.cookie = ""
            return clean
        }

        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: Keys.keys)
    }

    func loadActiveKeyID() -> String? {
        defaults.string(forKey: Keys.activeKey)
    }

    func saveActiveKeyID(_ keyID: String?) {
        defaults.setValue(keyID, forKey: Keys.activeKey)
    }

    func loadLockState() -> [String: String] {
        defaults.dictionary(forKey: Keys.lockState) as? [String: String] ?? [:]
    }

    func saveLockState(_ state: [String: String]) {
        defaults.setValue(state, forKey: Keys.lockState)
    }

    private func saveCookie(_ cookie: String, for keyID: String) {
        guard !keyID.isEmpty else { return }
        let account = "cookie.\(keyID)"
        let data = Data(cookie.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "hzcu.ios.lock",
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    private func loadCookie(for keyID: String) -> String? {
        guard !keyID.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "hzcu.ios.lock",
            kSecAttrAccount as String: "cookie.\(keyID)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
