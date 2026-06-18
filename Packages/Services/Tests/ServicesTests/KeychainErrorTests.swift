// KeychainErrorTests.swift — Unit tests for Keychain error display.

import Security
import Testing
@testable import Services

@Suite("KeychainError — user-facing descriptions")
struct KeychainErrorTests {
    @Test("Missing entitlement save errors explain local signing requirements")
    func missingEntitlementSaveErrorsExplainLocalSigningRequirements() {
        let error = KeychainError.saveFailed(errSecMissingEntitlement)

        #expect(error.localizedDescription.contains("Keychain entitlement"))
        #expect(error.localizedDescription.contains("signed app"))
    }
}
