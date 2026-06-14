// KeychainHelper.swift — Minimal Keychain wrapper for API token storage
// Phase 4: API + Cache

import Foundation
import LocalAuthentication
import Security

// MARK: - KeychainHelper

/// Minimal Keychain wrapper for storing and retrieving API tokens.
///
/// Used by `DiscogsClient` to persist the Personal Access Token securely.
/// Thread-safe: the Security framework handles concurrency internally.
///
/// Usage:
/// ```swift
/// let keychain = KeychainHelper()
/// try keychain.save(token: "my-pat", service: "com.genreupdater.discogs", account: "personal-access-token")
/// let token = try keychain.retrieve(service: "com.genreupdater.discogs", account: "personal-access-token")
/// ```
public struct KeychainHelper: Sendable {
    private let authenticationPrompt: String

    public init(
        authenticationPrompt: String = "Authenticate with biometrics to use stored API tokens."
    ) {
        self.authenticationPrompt = authenticationPrompt
    }

    /// Saves a token to the Keychain, replacing any existing value.
    ///
    /// Uses an upsert pattern: deletes the existing item first, then adds.
    /// This avoids `errSecDuplicateItem` when updating an existing token.
    ///
    /// - Parameters:
    ///   - token: The token string to store.
    ///   - service: The Keychain service identifier (e.g., `"com.genreupdater.discogs"`).
    ///   - account: The Keychain account identifier (e.g., `"personal-access-token"`).
    /// - Throws: `KeychainError.saveFailed` if the Security framework returns an error.
    public func save(
        token: String,
        service: String,
        account: String
    ) throws {
        let data = Data(token.utf8)
        let accessControl = try makeTokenAccessControl()

        // Delete existing item first (upsert pattern)
        try? delete(service: service, account: account)

        // Keep access control in the SecItemAdd query literal so static analyzers
        // can verify that stored API tokens require local authentication.
        let protectedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]

        let status = SecItemAdd(protectedQuery as CFDictionary, nil)
        if Self.shouldUseLegacyKeychainFallback(status) {
            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessControl as String: accessControl,
            ]
            let fallbackStatus = SecItemAdd(fallbackQuery as CFDictionary, nil)
            guard fallbackStatus == errSecSuccess else {
                throw KeychainError.saveFailed(fallbackStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves a token from the Keychain.
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier.
    ///   - account: The Keychain account identifier.
    /// - Returns: The stored token string, or `nil` if no matching item exists.
    /// - Throws: `KeychainError.retrieveFailed` for unexpected Security framework errors.
    public func retrieve(
        service: String,
        account: String
    ) throws -> String? {
        let authenticationContext = makeAuthenticationContext()
        let protectedQuery = makeProtectedRetrieveQuery(
            service: service,
            account: account,
            authenticationContext: authenticationContext
        )

        let protectedResult = try retrieveToken(
            query: protectedQuery,
            fallbackQuery: legacyQuery(
                service: service,
                account: account,
                shouldReturnData: true,
                authenticationContext: authenticationContext
            )
        )
        if protectedResult.status == errSecSuccess || protectedResult.status == errSecItemNotFound {
            return protectedResult.token
        }

        throw KeychainError.retrieveFailed(protectedResult.status)
    }

    private func retrieveToken(
        query: [String: Any],
        fallbackQuery: [String: Any],
        allowFallback: Bool = true
    ) throws -> (status: OSStatus, token: String?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return (status, nil) }
            return (status, String(data: data, encoding: .utf8))
        case errSecItemNotFound where allowFallback:
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        case errSecItemNotFound:
            return (status, nil)
        case _ where allowFallback && Self.shouldUseLegacyKeychainFallback(status):
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        default:
            return (status, nil)
        }
    }

    /// Deletes a token from the Keychain.
    ///
    /// Silently succeeds if no matching item exists (`errSecItemNotFound`).
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier.
    ///   - account: The Keychain account identifier.
    /// - Throws: `KeychainError.deleteFailed` for unexpected Security framework errors.
    public func delete(
        service: String,
        account: String
    ) throws {
        let protectedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(protectedQuery as CFDictionary)
        let fallbackStatus = SecItemDelete(legacyQuery(service: service, account: account) as CFDictionary)
        let validStatuses = [errSecSuccess, errSecItemNotFound, errSecNotAvailable, errSecMissingEntitlement]

        guard validStatuses.contains(status), validStatuses.contains(fallbackStatus) else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private static func shouldUseLegacyKeychainFallback(_ status: OSStatus) -> Bool {
        status == errSecNotAvailable || status == errSecMissingEntitlement
    }

    func makeProtectedSaveQuery(
        tokenData: Data,
        service: String,
        account: String
    ) throws -> [String: Any] {
        let accessControl = try makeTokenAccessControl()
        return makeProtectedSaveQuery(
            tokenData: tokenData,
            service: service,
            account: account,
            accessControl: accessControl
        )
    }

    private func makeProtectedSaveQuery(
        tokenData: Data,
        service: String,
        account: String,
        accessControl: SecAccessControl
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrAccessControl as String: accessControl,
        ]
    }

    func makeProtectedRetrieveQuery(
        service: String,
        account: String,
        authenticationContext: LAContext? = nil
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext ?? makeAuthenticationContext(),
        ]
    }

    func makeLegacySaveQuery(
        tokenData: Data,
        service: String,
        account: String
    ) throws -> [String: Any] {
        let accessControl = try makeTokenAccessControl()
        return makeLegacySaveQuery(
            tokenData: tokenData,
            service: service,
            account: account,
            accessControl: accessControl
        )
    }

    private func makeLegacySaveQuery(
        tokenData: Data,
        service: String,
        account: String,
        accessControl: SecAccessControl
    ) -> [String: Any] {
        var query = legacyQuery(service: service, account: account)
        query[kSecValueData as String] = tokenData
        query[kSecAttrAccessControl as String] = accessControl
        return query
    }

    private func makeTokenAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            throw KeychainError.accessControlCreationFailed
        }
        return accessControl
    }

    private func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = authenticationPrompt
        return context
    }

    private func legacyQuery(
        service: String,
        account: String,
        valueData: Data? = nil,
        shouldReturnData: Bool = false,
        authenticationContext: LAContext? = nil
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let valueData {
            query[kSecValueData as String] = valueData
        }
        if shouldReturnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        return query
    }
}

// MARK: - KeychainError

/// Errors from Keychain operations.
public enum KeychainError: Error, Sendable, LocalizedError {
    /// Creating the access-control policy for a protected token failed.
    case accessControlCreationFailed
    /// `SecItemAdd` returned a non-success status.
    case saveFailed(OSStatus)
    /// `SecItemCopyMatching` returned an unexpected status.
    case retrieveFailed(OSStatus)
    /// `SecItemDelete` returned an unexpected status.
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .accessControlCreationFailed:
            "Keychain access-control creation failed"
        case let .saveFailed(status):
            "Keychain save failed with OSStatus \(status)"
        case let .retrieveFailed(status):
            "Keychain retrieve failed with OSStatus \(status)"
        case let .deleteFailed(status):
            "Keychain delete failed with OSStatus \(status)"
        }
    }
}
