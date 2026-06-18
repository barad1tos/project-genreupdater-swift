import Foundation
import Security
import Testing
@testable import Services

@Suite("KeychainHelper - legacy migration")
struct KeychainHelperMigrationTests {
    private let testService = "com.genreupdater.test.\(UUID().uuidString)"
    private let testAccount = "discogs-token-test"

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
