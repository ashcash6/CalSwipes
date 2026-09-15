import Foundation
import Security

struct SessionVault {
    private let service = "BerkeleyPlate.Session"
    private let account = "current"

    private var query: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:account]
    }

    func load() throws -> SavedSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError(status) }
        return try JSONCoding.decoder().decode(SavedSession.self, from: data)
    }

    func save(_ session: SavedSession) throws {
        let data = try JSONCoding.encoder().encode(session)
        let values: [String: Any] = [kSecValueData as String:data,
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil)
            guard status == errSecSuccess else { throw VaultError(status) }
        } else if update != errSecSuccess { throw VaultError(update) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status) }
    }

    struct VaultError: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? { "Could not access secure sign-in storage. Unlock your iPhone and try again." }
    }
}
