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

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
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
