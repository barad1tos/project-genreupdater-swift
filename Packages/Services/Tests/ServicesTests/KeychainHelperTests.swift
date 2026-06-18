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

    @Test("Retrieve uses fallback query for marked local fallback token items")
    func retrieveUsesFallbackQueryForMarkedLocalFallbackTokenItems() throws {
        var queries: [[String: Any]] = []
        let tokenData = Data("local-fallback-token".utf8)
        let hooks = KeychainOperationHooks(
            addItem: { _ in errSecSuccess },
            copyMatching: { query, result in
                queries.append(query)
                if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
                    return errSecItemNotFound
                }
                result = [
                    kSecValueData as String: tokenData,
                    kSecAttrGeneric as String: KeychainHelper.localFallbackMarkerData,
                ] as NSDictionary
                return errSecSuccess
            },
            deleteItem: { _ in errSecItemNotFound }
        )
        let helper = KeychainHelper(operationHooks: hooks)

        #expect(try helper.retrieve(service: testService, account: testAccount) == "local-fallback-token")
        #expect(queries.count == 2)
        #expect(queries.first?[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(queries.last?[kSecUseDataProtectionKeychain as String] == nil)
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
}
