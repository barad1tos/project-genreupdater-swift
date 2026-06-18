import Foundation
import Security
@testable import Services

final class InMemoryKeychainOperations {
    private struct Item {
        let data: Data
        let isAccessControlled: Bool
        let isLocalFallback: Bool
        let usesDataProtection: Bool
    }

    var addQueries: [[String: Any]] = []
    var updateQueries: [(query: [String: Any], attributes: [String: Any])] = []
    var updateStatus: OSStatus = errSecSuccess
    private var items: [String: Item] = [:]

    var hooks: KeychainOperationHooks {
        KeychainOperationHooks(
            addItem: addItem,
            copyMatching: copyMatching,
            deleteItem: deleteItem,
            updateItem: updateItem
        )
    }

    func seed(
        token: String,
        service: String,
        account: String,
        isAccessControlled: Bool,
        isLocalFallback: Bool = false,
        usesDataProtection: Bool? = nil
    ) {
        seed(
            data: Data(token.utf8),
            service: service,
            account: account,
            isAccessControlled: isAccessControlled,
            isLocalFallback: isLocalFallback,
            usesDataProtection: usesDataProtection
        )
    }

    func seed(
        data: Data,
        service: String,
        account: String,
        isAccessControlled: Bool,
        isLocalFallback: Bool = false,
        usesDataProtection: Bool? = nil
    ) {
        items[key(service: service, account: account)] = Item(
            data: data,
            isAccessControlled: isAccessControlled,
            isLocalFallback: isLocalFallback,
            usesDataProtection: usesDataProtection ?? (isAccessControlled && !isLocalFallback)
        )
    }

    private func addItem(_ query: [String: Any]) -> OSStatus {
        addQueries.append(query)
        guard let data = query[kSecValueData as String] as? Data,
              let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }

        let itemKey = key(service: service, account: account)
        guard items[itemKey] == nil else {
            return errSecDuplicateItem
        }

        items[itemKey] = Item(
            data: data,
            isAccessControlled: query[kSecAttrAccessControl as String] != nil,
            isLocalFallback: (query[kSecAttrGeneric as String] as? Data) == KeychainHelper.localFallbackMarkerData,
            usesDataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool == true
        )
        return errSecSuccess
    }

    private func copyMatching(
        _ query: [String: Any],
        _ result: inout AnyObject?
    ) -> OSStatus {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              let item = items[key(service: service, account: account)] else {
            return errSecItemNotFound
        }
        let queryUsesDataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        guard queryUsesDataProtection == item.usesDataProtection else {
            return errSecItemNotFound
        }

        var attributes: [String: Any] = [
            kSecValueData as String: item.data,
        ]
        if item.isAccessControlled {
            attributes[kSecAttrAccessControl as String] = "access-controlled"
        }
        if item.isLocalFallback {
            attributes[kSecAttrGeneric as String] = KeychainHelper.localFallbackMarkerData
        }
        result = attributes as NSDictionary
        return errSecSuccess
    }

    private func deleteItem(_ query: [String: Any]) -> OSStatus {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }

        return items.removeValue(forKey: key(service: service, account: account)) == nil
            ? errSecItemNotFound
            : errSecSuccess
    }

    private func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateQueries.append((query, attributes))
        guard updateStatus == errSecSuccess else {
            return updateStatus
        }
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }

        let itemKey = key(service: service, account: account)
        guard let existingItem = items[itemKey] else {
            return errSecItemNotFound
        }

        items[itemKey] = Item(
            data: data,
            isAccessControlled: attributes[kSecAttrAccessControl as String] != nil || existingItem.isAccessControlled,
            isLocalFallback: (attributes[kSecAttrGeneric as String] as? Data) ==
                KeychainHelper.localFallbackMarkerData ||
                existingItem.isLocalFallback,
            usesDataProtection: existingItem.usesDataProtection
        )
        return errSecSuccess
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}
