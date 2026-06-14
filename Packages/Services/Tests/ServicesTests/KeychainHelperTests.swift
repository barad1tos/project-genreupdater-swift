// KeychainHelperTests.swift — Unit tests for Keychain token storage
// Phase 4: API + Cache

import Foundation
import LocalAuthentication
import Testing
@testable import Services

// MARK: - KeychainHelperTests

@Suite("KeychainHelper — Keychain token storage and retrieval")
struct KeychainHelperTests {
    private let testService = "com.genreupdater.test.\(UUID().uuidString)"
    private let testAccount = "discogs-token-test"

    @Test("Protected save query requires user authentication")
    func protectedSaveQueryRequiresUserAuthentication() throws {
        let helper = KeychainHelper()
        let tokenData = Data("test-token-123".utf8)

        let query = try helper.makeProtectedSaveQuery(
            tokenData: tokenData,
            service: testService,
            account: testAccount
        )

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == testService)
        #expect(query[kSecAttrAccount as String] as? String == testAccount)
        #expect(query[kSecValueData as String] as? Data == tokenData)
        #expect(query[kSecAttrAccessControl as String] != nil)
        #expect(query[kSecAttrAccessible as String] == nil)
    }

    @Test("Legacy fallback save query also requires user authentication")
    func legacyFallbackSaveQueryAlsoRequiresUserAuthentication() throws {
        let helper = KeychainHelper()
        let tokenData = Data("fallback-token".utf8)

        let query = try helper.makeLegacySaveQuery(
            tokenData: tokenData,
            service: testService,
            account: testAccount
        )

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrService as String] as? String == testService)
        #expect(query[kSecAttrAccount as String] as? String == testAccount)
        #expect(query[kSecValueData as String] as? Data == tokenData)
        #expect(query[kSecAttrAccessControl as String] != nil)
        #expect(query[kSecAttrAccessible as String] == nil)
    }

    @Test("Protected retrieve query uses an authentication prompt")
    func protectedRetrieveQueryUsesAuthenticationPrompt() throws {
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
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        let authenticationContext = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(authenticationContext.localizedReason == "Authenticate with biometrics to use stored API tokens.")
    }

    @Test("Retrieve returns nil for missing token")
    func retrieveMissing() throws {
        let helper = KeychainHelper()
        let result = try helper.retrieve(
            service: testService,
            account: "nonexistent-\(UUID().uuidString)"
        )
        #expect(result == nil)
    }
}
