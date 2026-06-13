// KeychainHelper.swift — Minimal Keychain wrapper for API token storage
// Phase 4: API + Cache

import Foundation
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
    public init() {}

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

        // Delete existing item first (upsert pattern)
        try? delete(service: service, account: account)

        let protectedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // API tokens must be available to non-interactive batch workflows.
        // swiftformat:disable wrap
        // swiftlint:disable:next line_length
        let status = SecItemAdd(protectedQuery as CFDictionary, nil) // nosemgrep: swift.biometrics-and-auth.missing-user-auth.keychain-without-user-auth
        // swiftformat:enable wrap
        if Self.shouldUseLegacyKeychainFallback(status) {
            let fallbackStatus = SecItemAdd(
                legacyQuery(service: service, account: account, valueData: data) as CFDictionary,
                nil
            )
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
        let protectedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let protectedResult = try retrieveToken(
            query: protectedQuery,
            fallbackQuery: legacyQuery(service: service, account: account, shouldReturnData: true)
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

    private func legacyQuery(
        service: String,
        account: String,
        valueData: Data? = nil,
        shouldReturnData: Bool = false
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
        return query
    }
}

// MARK: - KeychainError

/// Errors from Keychain operations.
public enum KeychainError: Error, Sendable, LocalizedError {
    /// `SecItemAdd` returned a non-success status.
    case saveFailed(OSStatus)
    /// `SecItemCopyMatching` returned an unexpected status.
    case retrieveFailed(OSStatus)
    /// `SecItemDelete` returned an unexpected status.
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            "Keychain save failed with OSStatus \(status)"
        case let .retrieveFailed(status):
            "Keychain retrieve failed with OSStatus \(status)"
        case let .deleteFailed(status):
            "Keychain delete failed with OSStatus \(status)"
        }
    }
}
