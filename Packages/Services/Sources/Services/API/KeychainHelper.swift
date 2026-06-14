// KeychainHelper.swift — Minimal Keychain wrapper for API token storage
// Phase 4: API + Cache

import Foundation
import LocalAuthentication
import Security

// MARK: - KeychainAuthenticationPolicy

/// Local authentication policy for stored API tokens.
public enum KeychainAuthenticationPolicy: Sendable {
    /// Require local user presence before a stored token can be used.
    ///
    /// On macOS this allows the system-supported local authentication method
    /// for the account, such as Touch ID or the account password. This keeps
    /// Keychain token storage usable on Macs without enrolled biometrics while
    /// still requiring local authentication.
    case localUserPresence

    var accessControlFlags: SecAccessControlCreateFlags {
        .userPresence
    }

    var defaultPrompt: String {
        "Authenticate to use stored API tokens."
    }
}

final class KeychainOperationHooks: @unchecked Sendable {
    typealias AddItem = ([String: Any]) -> OSStatus
    typealias CopyMatching = ([String: Any], inout AnyObject?) -> OSStatus
    typealias DeleteItem = ([String: Any]) -> OSStatus

    let addItem: AddItem
    let copyMatching: CopyMatching
    let deleteItem: DeleteItem

    init(
        addItem: @escaping AddItem,
        copyMatching: @escaping CopyMatching,
        deleteItem: @escaping DeleteItem
    ) {
        self.addItem = addItem
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
    }
}

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
    private let authenticationPolicy: KeychainAuthenticationPolicy
    private let authenticationPrompt: String
    private let operationHooks: KeychainOperationHooks?

    public init(
        authenticationPolicy: KeychainAuthenticationPolicy = .localUserPresence,
        authenticationPrompt: String? = nil
    ) {
        self.authenticationPolicy = authenticationPolicy
        self.authenticationPrompt = authenticationPrompt ?? authenticationPolicy.defaultPrompt
        self.operationHooks = nil
    }

    init(
        authenticationPolicy: KeychainAuthenticationPolicy = .localUserPresence,
        authenticationPrompt: String? = nil,
        operationHooks: KeychainOperationHooks
    ) {
        self.authenticationPolicy = authenticationPolicy
        self.authenticationPrompt = authenticationPrompt ?? authenticationPolicy.defaultPrompt
        self.operationHooks = operationHooks
    }

    /// Saves a token to the Keychain, replacing any existing value.
    ///
    /// Stored tokens require the configured local authentication policy before
    /// future reads can return token data.
    ///
    /// Uses an upsert pattern: deletes the existing item first, then adds.
    /// This avoids `errSecDuplicateItem` when updating an existing token.
    ///
    /// - Parameters:
    ///   - token: The token string to store.
    ///   - service: The Keychain service identifier (e.g., `"com.genreupdater.discogs"`).
    ///   - account: The Keychain account identifier (e.g., `"personal-access-token"`).
    /// - Throws: `KeychainError.accessControlCreationFailed` if the local-authentication policy
    ///   cannot be created, `KeychainError.authenticationFailed` for local-authentication failures,
    ///   `KeychainError.deleteFailed` if replacing an existing item fails, or
    ///   `KeychainError.saveFailed` if the Security framework returns another error while adding.
    public func save(
        token: String,
        service: String,
        account: String
    ) throws {
        let data = Data(token.utf8)
        let accessControl = try makeTokenAccessControl()

        // Delete existing item first (upsert pattern)
        try delete(service: service, account: account)

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

        let status: OSStatus
        if let operationHooks {
            status = operationHooks.addItem(protectedQuery)
        } else {
            let protectedStatus = SecItemAdd(protectedQuery as CFDictionary, nil)
            status = protectedStatus
        }

        if Self.shouldUseLegacyKeychainFallback(status) {
            let fallbackQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessControl as String: accessControl,
            ]
            let fallbackStatus: OSStatus
            if let operationHooks {
                fallbackStatus = operationHooks.addItem(fallbackQuery)
            } else {
                let legacyStatus = SecItemAdd(fallbackQuery as CFDictionary, nil)
                fallbackStatus = legacyStatus
            }
            guard fallbackStatus == errSecSuccess else {
                throw Self.error(for: .save, status: fallbackStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw Self.error(for: .save, status: status)
        }
    }

    /// Retrieves a token from the Keychain.
    ///
    /// Reading a protected token can prompt for local authentication. Existing
    /// unprotected token items are rejected so callers can ask the user to save
    /// the token again under the current local-authentication policy.
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier.
    ///   - account: The Keychain account identifier.
    /// - Returns: The stored token string, or `nil` if no matching item exists.
    /// - Throws: `KeychainError.authenticationFailed` for local-authentication failures,
    ///   `KeychainError.unprotectedItemRequiresResave` for legacy unprotected token items,
    ///   `KeychainError.invalidTokenData` for corrupt token data, or
    ///   `KeychainError.retrieveFailed` for other Security framework errors.
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
            if protectedResult.isUnprotectedItem {
                throw KeychainError.unprotectedItemRequiresResave
            }
            return protectedResult.token
        }

        throw Self.error(for: .retrieve, status: protectedResult.status)
    }

    private func retrieveToken(
        query: [String: Any],
        fallbackQuery: [String: Any],
        allowFallback: Bool = true
    ) throws -> (status: OSStatus, token: String?, isUnprotectedItem: Bool) {
        var result: AnyObject?
        // swiftformat:disable conditionalAssignment
        let status: OSStatus
        if let operationHooks {
            status = operationHooks.copyMatching(query, &result)
        } else {
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        // swiftformat:enable conditionalAssignment

        switch status {
        case errSecSuccess:
            let tokenResult = try parseTokenResult(result)
            return (status, tokenResult.token, !tokenResult.isAccessControlled)
        case errSecItemNotFound where allowFallback:
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        case errSecItemNotFound:
            return (status, nil, false)
        case _ where allowFallback && Self.shouldUseLegacyKeychainFallback(status):
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        default:
            return (status, nil, false)
        }
    }

    /// Deletes a token from the Keychain.
    ///
    /// Silently succeeds if no matching item exists (`errSecItemNotFound`).
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier.
    ///   - account: The Keychain account identifier.
    /// - Throws: `KeychainError.authenticationFailed` for local-authentication failures, or
    ///   `KeychainError.deleteFailed` for other unexpected Security framework errors.
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

        let status = deleteItem(protectedQuery)
        let fallbackStatus = deleteItem(legacyQuery(service: service, account: account))
        let validStatuses = [errSecSuccess, errSecItemNotFound, errSecNotAvailable, errSecMissingEntitlement]

        if !validStatuses.contains(status) {
            throw Self.error(for: .delete, status: status)
        }
        if !validStatuses.contains(fallbackStatus) {
            throw Self.error(for: .delete, status: fallbackStatus)
        }
    }

    private static func shouldUseLegacyKeychainFallback(_ status: OSStatus) -> Bool {
        status == errSecNotAvailable || status == errSecMissingEntitlement
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
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext ?? makeAuthenticationContext(),
        ]
    }

    private func makeTokenAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            authenticationPolicy.accessControlFlags,
            &error
        ) else {
            let failureDescription = error?.takeRetainedValue().localizedDescription
            throw KeychainError.accessControlCreationFailed(failureDescription)
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
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        return query
    }

    private func parseTokenResult(_ result: AnyObject?) throws -> (token: String, isAccessControlled: Bool) {
        guard let attributes = result as? NSDictionary,
              let data = (attributes[kSecValueData] as? Data) ?? (attributes[kSecValueData as String] as? Data) else {
            throw KeychainError.invalidTokenData
        }

        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw KeychainError.invalidTokenData
        }

        return (
            token: token,
            isAccessControlled: attributes[kSecAttrAccessControl] != nil ||
                attributes[kSecAttrAccessControl as String] != nil
        )
    }

    private func deleteItem(_ query: [String: Any]) -> OSStatus {
        if let operationHooks {
            return operationHooks.deleteItem(query)
        }
        return SecItemDelete(query as CFDictionary)
    }

    private static func error(for operation: KeychainOperation, status: OSStatus) -> KeychainError {
        if isAuthenticationFailureStatus(status) {
            return .authenticationFailed(status)
        }

        switch operation {
        case .save:
            return .saveFailed(status)
        case .retrieve:
            return .retrieveFailed(status)
        case .delete:
            return .deleteFailed(status)
        }
    }

    private static func isAuthenticationFailureStatus(_ status: OSStatus) -> Bool {
        status == errSecAuthFailed ||
            status == errSecUserCanceled ||
            status == errSecInteractionNotAllowed
    }
}

private enum KeychainOperation {
    case save
    case retrieve
    case delete
}

// MARK: - KeychainError

/// Errors from Keychain operations.
public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    /// Creating the access-control policy for a protected token failed.
    case accessControlCreationFailed(String?)
    /// Local authentication was unavailable, cancelled, or failed.
    case authenticationFailed(OSStatus)
    /// A legacy token item exists without the current local-authentication policy.
    case unprotectedItemRequiresResave
    /// The stored token item could not be decoded into a non-empty UTF-8 string.
    case invalidTokenData
    /// `SecItemAdd` returned a non-success status.
    case saveFailed(OSStatus)
    /// `SecItemCopyMatching` returned an unexpected status.
    case retrieveFailed(OSStatus)
    /// `SecItemDelete` returned an unexpected status.
    case deleteFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .accessControlCreationFailed(description):
            if let description, !description.isEmpty {
                "Keychain access-control creation failed: \(description)"
            } else {
                "Keychain access-control creation failed"
            }
        case let .authenticationFailed(status):
            "Keychain authentication failed with OSStatus \(status)"
        case .unprotectedItemRequiresResave:
            "Stored Keychain token must be saved again to require local authentication"
        case .invalidTokenData:
            "Stored Keychain token data is invalid"
        case let .saveFailed(status):
            "Keychain save failed with OSStatus \(status)"
        case let .retrieveFailed(status):
            "Keychain retrieve failed with OSStatus \(status)"
        case let .deleteFailed(status):
            "Keychain delete failed with OSStatus \(status)"
        }
    }
}
