// KeychainHelperTests.swift — Unit tests for Keychain token storage
// Phase 4: API + Cache

import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Services

// MARK: - KeychainHelperTests

@Suite("KeychainHelper — Keychain token storage and retrieval")
struct KeychainHelperTests {
    private let testService = "com.genreupdater.test.\(UUID().uuidString)"
    private let testAccount = "discogs-token-test"

    @Test("Save passes a protected query to Security")
    func savePassesProtectedQueryToSecurity() throws {
        var addQueries: [[String: Any]] = []
        let hooks = KeychainOperationHooks(
            addItem: { query in
                addQueries.append(query)
                return errSecSuccess
            },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in errSecItemNotFound }
        )
        let helper = KeychainHelper(operationHooks: hooks)
        let tokenData = Data("test-token-123".utf8)

        try helper.save(
            token: "test-token-123",
            service: testService,
            account: testAccount
        )

        let query = try #require(addQueries.first)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == testService)
        #expect(query[kSecAttrAccount as String] as? String == testAccount)
        #expect(query[kSecValueData as String] as? Data == tokenData)
        #expect(query[kSecAttrAccessControl as String] != nil)
        #expect(query[kSecAttrAccessible as String] == nil)
    }

    @Test("Save fallback stores a marked local Keychain item when protected storage lacks entitlements")
    func saveFallbackStoresMarkedLocalKeychainItemWhenProtectedStorageLacksEntitlements() throws {
        var addQueries: [[String: Any]] = []
        var statuses: [OSStatus] = [errSecMissingEntitlement, errSecSuccess]
        let hooks = KeychainOperationHooks(
            addItem: { query in
                addQueries.append(query)
                return statuses.removeFirst()
            },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in errSecItemNotFound }
        )
        let helper = KeychainHelper(operationHooks: hooks)
        let tokenData = Data("fallback-token".utf8)

        let result = try helper.save(
            token: "fallback-token",
            service: testService,
            account: testAccount
        )

        #expect(result == .localFallback)
        #expect(addQueries.count == 2)
        let query = try #require(addQueries.last)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrService as String] as? String == testService)
        #expect(query[kSecAttrAccount as String] as? String == testAccount)
        #expect(query[kSecValueData as String] as? Data == tokenData)
        #expect(query[kSecAttrAccessControl as String] == nil)
        #expect(query[kSecAttrGeneric as String] as? Data == KeychainHelper.localFallbackMarkerData)
        #expect(
            query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
    }

    @Test("Retrieve accepts local fallback token items that were marked by this app")
    func retrieveAcceptsMarkedLocalFallbackTokenItems() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "local-fallback-token",
            service: testService,
            account: testAccount,
            isAccessControlled: false,
            isLocalFallback: true
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(try helper.retrieve(service: testService, account: testAccount) == "local-fallback-token")
    }

    @Test("Save rejects empty token input before touching Security")
    func saveRejectsEmptyTokenInputBeforeTouchingSecurity() throws {
        var addWasCalled = false
        var deleteWasCalled = false
        let hooks = KeychainOperationHooks(
            addItem: { _ in
                addWasCalled = true
                return errSecSuccess
            },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in
                deleteWasCalled = true
                return errSecSuccess
            }
        )
        let helper = KeychainHelper(operationHooks: hooks)

        #expect(throws: KeychainError.emptyToken) {
            try helper.save(token: "   \n\t", service: testService, account: testAccount)
        }
        #expect(addWasCalled == false)
        #expect(deleteWasCalled == false)
    }

    @Test("Save trims token input before storing")
    func saveTrimsTokenInputBeforeStoring() throws {
        let keychain = InMemoryKeychainOperations()
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        try helper.save(token: "  trimmed-token\n", service: testService, account: testAccount)

        #expect(try helper.retrieve(service: testService, account: testAccount) == "trimmed-token")
    }

    @Test("Public save retrieve overwrite and delete lifecycle uses protected token items")
    func publicLifecycleUsesProtectedTokenItems() throws {
        let keychain = InMemoryKeychainOperations()
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        try helper.save(token: "first-token", service: testService, account: testAccount)
        #expect(try helper.retrieve(service: testService, account: testAccount) == "first-token")

        try helper.save(token: "second-token", service: testService, account: testAccount)
        #expect(try helper.retrieve(service: testService, account: testAccount) == "second-token")

        try helper.delete(service: testService, account: testAccount)
        #expect(try helper.retrieve(service: testService, account: testAccount) == nil)
        #expect(keychain.addQueries.allSatisfy { $0[kSecAttrAccessControl as String] != nil })
    }

    @Test("Save replacement failure preserves existing token")
    func saveReplacementFailurePreservesExistingToken() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "existing-token",
            service: testService,
            account: testAccount,
            isAccessControlled: true
        )
        keychain.updateStatus = errSecAuthFailed
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(throws: KeychainError.authenticationFailed(errSecAuthFailed)) {
            try helper.save(token: "replacement-token", service: testService, account: testAccount)
        }
        #expect(try helper.retrieve(service: testService, account: testAccount) == "existing-token")
    }

    @Test("Delete maps authentication failures to authentication errors")
    func deleteMapsAuthenticationFailuresToAuthenticationErrors() throws {
        var deleteStatuses: [OSStatus] = [errSecAuthFailed, errSecItemNotFound]
        let hooks = KeychainOperationHooks(
            addItem: { _ in errSecSuccess },
            copyMatching: { _, _ in errSecItemNotFound },
            deleteItem: { _ in
                deleteStatuses.removeFirst()
            }
        )
        let helper = KeychainHelper(operationHooks: hooks)

        #expect(throws: KeychainError.authenticationFailed(errSecAuthFailed)) {
            try helper.delete(service: testService, account: testAccount)
        }
    }

    @Test("Retrieve rejects legacy unprotected token items")
    func retrieveRejectsLegacyUnprotectedTokenItems() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "legacy-token",
            service: testService,
            account: testAccount,
            isAccessControlled: false
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(throws: KeychainError.unprotectedItemRequiresResave) {
            try helper.retrieve(service: testService, account: testAccount)
        }
    }

    @Test("Retrieve throws on corrupt token data")
    func retrieveThrowsOnCorruptTokenData() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            data: Data([0xFF]),
            service: testService,
            account: testAccount,
            isAccessControlled: true
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(throws: KeychainError.invalidTokenData) {
            try helper.retrieve(service: testService, account: testAccount)
        }
    }

    @Test("Retrieve rejects legacy whitespace-only token data")
    func retrieveRejectsLegacyWhitespaceOnlyTokenData() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "   \n\t",
            service: testService,
            account: testAccount,
            isAccessControlled: true
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(throws: KeychainError.invalidTokenData) {
            try helper.retrieve(service: testService, account: testAccount)
        }
    }

    @Test("Retrieve trims legacy token data")
    func retrieveTrimsLegacyTokenData() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "  legacy-token\n",
            service: testService,
            account: testAccount,
            isAccessControlled: true
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(try helper.retrieve(service: testService, account: testAccount) == "legacy-token")
    }

    @Test("Discogs saved token migrates previous Settings keychain item")
    func discogsSavedTokenMigratesPreviousSettingsKeychainItem() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "legacy-discogs-token",
            service: DiscogsClient.legacyKeychainService,
            account: DiscogsClient.legacyKeychainAccount,
            isAccessControlled: true
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        let token = try DiscogsClient.retrieveSavedToken(keychain: helper)

        #expect(token == "legacy-discogs-token")
        #expect(try helper.retrieve(
            service: DiscogsClient.keychainService,
            account: DiscogsClient.keychainAccount
        ) == "legacy-discogs-token")
        #expect(try helper.retrieve(
            service: DiscogsClient.legacyKeychainService,
            account: DiscogsClient.legacyKeychainAccount
        ) == nil)
    }

    @Test("Discogs saved token surfaces unsafe legacy Settings item")
    func discogsSavedTokenSurfacesUnsafeLegacySettingsItem() throws {
        let keychain = InMemoryKeychainOperations()
        keychain.seed(
            token: "legacy-discogs-token",
            service: DiscogsClient.legacyKeychainService,
            account: DiscogsClient.legacyKeychainAccount,
            isAccessControlled: false
        )
        let helper = KeychainHelper(operationHooks: keychain.hooks)

        #expect(throws: KeychainError.unprotectedItemRequiresResave) {
            try DiscogsClient.retrieveSavedToken(keychain: helper)
        }
    }

    @Test("Retrieve maps authentication failures to authentication errors", arguments: [
        errSecUserCanceled,
        errSecInteractionNotAllowed,
    ])
    func retrieveMapsAuthenticationFailuresToAuthenticationErrors(status: OSStatus) throws {
        let hooks = KeychainOperationHooks(
            addItem: { _ in errSecSuccess },
            copyMatching: { _, _ in status },
            deleteItem: { _ in errSecItemNotFound }
        )
        let helper = KeychainHelper(operationHooks: hooks)

        #expect(throws: KeychainError.authenticationFailed(status)) {
            try helper.retrieve(service: testService, account: testAccount)
        }
    }

    @Test("Protected retrieve query uses an authentication context")
    func protectedRetrieveQueryUsesAuthenticationContext() {
        let helper = KeychainHelper()
        let query = helper.makeProtectedRetrieveQuery(
            service: testService,
            account: testAccount
        )

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == testService)
        #expect(query[kSecAttrAccount as String] as? String == testAccount)
        #expect(query[kSecReturnData as String] as? Bool == true)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecUseAuthenticationContext as String] is LAContext)
        #expect(
            KeychainAuthenticationPolicy.localUserPresence.defaultPrompt == "Authenticate to use stored API tokens."
        )
    }

    @Test("Retrieve returns nil for missing token")
    func retrieveMissing() throws {
        let keychain = InMemoryKeychainOperations()
        let helper = KeychainHelper(operationHooks: keychain.hooks)
        let result = try helper.retrieve(
            service: testService,
            account: "nonexistent-\(UUID().uuidString)"
        )
        #expect(result == nil)
    }

    @Test(
        "Security-backed Keychain lifecycle can run manually",
        .enabled(if: ProcessInfo.processInfo.environment["GENREUPDATER_RUN_KEYCHAIN_INTEGRATION"] == "1")
    )
    func securityBackedKeychainLifecycle() throws {
        let service = "com.genreupdater.integration.\(UUID().uuidString)"
        let account = "discogs-token-integration"
        let helper = KeychainHelper(authenticationPrompt: "Authenticate to test GenreUpdater Keychain token access.")
        let token = "integration-token-\(UUID().uuidString)"

        defer {
            try? helper.delete(service: service, account: account)
        }

        try helper.save(token: token, service: service, account: account)
        #expect(try helper.retrieve(service: service, account: account) == token)

        try helper.delete(service: service, account: account)
        #expect(try helper.retrieve(service: service, account: account) == nil)
    }
}

private final class InMemoryKeychainOperations {
    struct Item {
        let data: Data
        let isAccessControlled: Bool
        let isLocalFallback: Bool
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
        isLocalFallback: Bool = false
    ) {
        seed(
            data: Data(token.utf8),
            service: service,
            account: account,
            isAccessControlled: isAccessControlled,
            isLocalFallback: isLocalFallback
        )
    }

    func seed(
        data: Data,
        service: String,
        account: String,
        isAccessControlled: Bool,
        isLocalFallback: Bool = false
    ) {
        items[key(service: service, account: account)] = Item(
            data: data,
            isAccessControlled: isAccessControlled,
            isLocalFallback: isLocalFallback
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
            isLocalFallback: (query[kSecAttrGeneric as String] as? Data) == KeychainHelper.localFallbackMarkerData
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
                existingItem.isLocalFallback
        )
        return errSecSuccess
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1F}\(account)"
    }
}
