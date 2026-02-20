// KeychainHelperTests.swift — Unit tests for Keychain token storage
// Phase 4: API + Cache

import Foundation
import Testing
@testable import Services

// MARK: - KeychainHelperTests

@Suite("KeychainHelper — Keychain token storage and retrieval")
struct KeychainHelperTests {
    private let testService = "com.genreupdater.test.\(UUID().uuidString)"
    private let testAccount = "discogs-token-test"

    @Test("Save and retrieve token roundtrip")
    func saveAndRetrieve() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "test-token-123",
            service: testService,
            account: testAccount
        )

        let retrieved = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(retrieved == "test-token-123")

        // Cleanup
        try helper.delete(service: testService, account: testAccount)
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

    @Test("Delete removes token")
    func deleteToken() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "to-delete",
            service: testService,
            account: testAccount
        )
        try helper.delete(
            service: testService,
            account: testAccount
        )

        let result = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(result == nil)
    }

    @Test("Save overwrites existing token")
    func saveOverwrites() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "old-token",
            service: testService,
            account: testAccount
        )
        try helper.save(
            token: "new-token",
            service: testService,
            account: testAccount
        )

        let result = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(result == "new-token")

        // Cleanup
        try helper.delete(service: testService, account: testAccount)
    }
}
