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
    typealias UpdateItem = ([String: Any], [String: Any]) -> OSStatus

    let addItem: AddItem
    let copyMatching: CopyMatching
    let deleteItem: DeleteItem
    let updateItem: UpdateItem

    init(
        addItem: @escaping AddItem,
        copyMatching: @escaping CopyMatching,
        deleteItem: @escaping DeleteItem,
        updateItem: @escaping UpdateItem = { _, _ in errSecUnimplemented }
    ) {
        self.addItem = addItem
        self.copyMatching = copyMatching
        self.deleteItem = deleteItem
        self.updateItem = updateItem
    }
}

private struct KeychainRetrieveTokenResult {
    let status: OSStatus
    let token: String?
    let isUnprotectedItem: Bool
    let isLocalFallbackItem: Bool
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
    static let localFallbackMarkerData = Data("com.genreupdater.keychain.local-fallback.v1".utf8)

    private let authenticationPolicy: KeychainAuthenticationPolicy
    private let authenticationPrompt: String
    private let allowsLocalFallback: Bool
    private let operationHooks: KeychainOperationHooks?

    public init(
        authenticationPolicy: KeychainAuthenticationPolicy = .localUserPresence,
        authenticationPrompt: String? = nil,
        allowsLocalFallback: Bool = Self.defaultAllowsLocalFallback
    ) {
        self.authenticationPolicy = authenticationPolicy
        self.authenticationPrompt = authenticationPrompt ?? authenticationPolicy.defaultPrompt
        self.allowsLocalFallback = allowsLocalFallback
        self.operationHooks = nil
    }

    init(
        authenticationPolicy: KeychainAuthenticationPolicy = .localUserPresence,
        authenticationPrompt: String? = nil,
        allowsLocalFallback: Bool = Self.defaultAllowsLocalFallback,
        operationHooks: KeychainOperationHooks
    ) {
        self.authenticationPolicy = authenticationPolicy
        self.authenticationPrompt = authenticationPrompt ?? authenticationPolicy.defaultPrompt
        self.allowsLocalFallback = allowsLocalFallback
        self.operationHooks = operationHooks
    }

    /// Saves a token to the Keychain, replacing any existing value.
    ///
    /// Stored tokens require the configured local authentication policy before
    /// future reads can return token data.
    ///
    /// Uses an add-then-update upsert pattern so a failed replacement does not
    /// delete an existing valid token.
    ///
    /// - Parameters:
    ///   - token: The token string to store.
    ///   - service: The Keychain service identifier (e.g., `"com.genreupdater.discogs"`).
    ///   - account: The Keychain account identifier (e.g., `"personal-access-token"`).
    /// - Throws: `KeychainError.emptyToken` for blank input,
    ///   `KeychainError.accessControlCreationFailed` if the local-authentication policy cannot be created,
    ///   `KeychainError.authenticationFailed` for local-authentication failures, or
    ///   `KeychainError.saveFailed` if the Security framework returns another error while adding or updating.
    @discardableResult
    public func save(
        token: String,
        service: String,
        account: String
    ) throws -> KeychainSaveResult {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw KeychainError.emptyToken
        }

        let data = Data(trimmedToken.utf8)
        let accessControl = try makeTokenAccessControl()

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

        let status = addItem(protectedQuery)
        if status == errSecSuccess {
            return .protected
        }

        if status == errSecDuplicateItem {
            try updateToken(
                matching: protectedSaveQuery(service: service, account: account),
                data: data,
                accessControl: accessControl
            )
            return .protected
        }

        if allowsLocalFallback, Self.shouldUseLegacyKeychainFallback(status) {
            let fallbackQuery = localFallbackSaveQuery(service: service, account: account, data: data)
            let fallbackStatus = addItem(fallbackQuery)
            if fallbackStatus == errSecSuccess {
                return .localFallback
            }
            if fallbackStatus == errSecDuplicateItem {
                try updateLocalFallbackToken(
                    matching: legacyQuery(service: service, account: account),
                    data: data
                )
                return .localFallback
            }
            throw Self.error(for: .save, status: fallbackStatus)
        }

        throw Self.error(for: .save, status: status)
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
            ),
            allowFallback: allowsLocalFallback
        )
        if protectedResult.status == errSecSuccess || protectedResult.status == errSecItemNotFound {
            if protectedResult.isUnprotectedItem, !protectedResult.isLocalFallbackItem {
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
    ) throws -> KeychainRetrieveTokenResult {
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
            return KeychainRetrieveTokenResult(
                status: status,
                token: tokenResult.token,
                isUnprotectedItem: !tokenResult.isAccessControlled,
                isLocalFallbackItem: tokenResult.isLocalFallback
            )
        case errSecItemNotFound where allowFallback:
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        case errSecItemNotFound:
            return KeychainRetrieveTokenResult(
                status: status,
                token: nil,
                isUnprotectedItem: false,
                isLocalFallbackItem: false
            )
        case _ where allowFallback && Self.shouldUseLegacyKeychainFallback(status):
            return try retrieveToken(
                query: fallbackQuery,
                fallbackQuery: fallbackQuery,
                allowFallback: false
            )
        default:
            return KeychainRetrieveTokenResult(
                status: status,
                token: nil,
                isUnprotectedItem: false,
                isLocalFallbackItem: false
            )
        }
    }

    /// Deletes a token from the Keychain.
    ///
    /// Silently succeeds if no matching item exists (`errSecItemNotFound`).
    ///
    /// - Parameters:
    ///   - service: The Keychain service identifier.
    ///   - account: The Keychain account identifier.
    /// - Returns: `true` when at least one matching item was deleted.
    /// - Throws: `KeychainError.authenticationFailed` for local-authentication failures, or
    ///   `KeychainError.deleteFailed` for other unexpected Security framework errors.
    @discardableResult
    public func delete(
        service: String,
        account: String
    ) throws -> Bool {
        try delete(service: service, account: account) {}
    }

    func delete(
        service: String,
        account: String,
        onDelete: () -> Void
    ) throws -> Bool {
        let protectedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = deleteItem(protectedQuery)
        let fallbackStatus = deleteItem(legacyQuery(service: service, account: account))
        if status == errSecSuccess {
            onDelete()
        }
        if fallbackStatus == errSecSuccess {
            onDelete()
        }
        let validStatuses = [errSecSuccess, errSecItemNotFound, errSecNotAvailable, errSecMissingEntitlement]

        if !validStatuses.contains(status) {
            throw Self.error(for: .delete, status: status)
        }
        if !validStatuses.contains(fallbackStatus) {
            throw Self.error(for: .delete, status: fallbackStatus)
        }
        return status == errSecSuccess || fallbackStatus == errSecSuccess
    }
}

extension KeychainHelper {
    @usableFromInline static var defaultAllowsLocalFallback: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func shouldUseLegacyKeychainFallback(_ status: OSStatus) -> Bool {
        status == errSecNotAvailable || status == errSecMissingEntitlement
    }

    private func protectedSaveQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: makeAuthenticationContext(),
        ]
    }

    private func localFallbackSaveQuery(service: String, account: String, data: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrGeneric as String: Self.localFallbackMarkerData,
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

    private func parseTokenResult(
        _ result: AnyObject?
    ) throws -> (token: String, isAccessControlled: Bool, isLocalFallback: Bool) {
        guard let attributes = result as? NSDictionary,
              let data = (attributes[kSecValueData] as? Data) ?? (attributes[kSecValueData as String] as? Data) else {
            throw KeychainError.invalidTokenData
        }

        guard let decodedToken = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidTokenData
        }

        let token = decodedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw KeychainError.invalidTokenData
        }

        return (
            token: token,
            isAccessControlled: attributes[kSecAttrAccessControl] != nil ||
                attributes[kSecAttrAccessControl as String] != nil,
            isLocalFallback: (attributes[kSecAttrGeneric] as? Data) == Self.localFallbackMarkerData ||
                (attributes[kSecAttrGeneric as String] as? Data) == Self.localFallbackMarkerData
        )
    }

    private func deleteItem(_ query: [String: Any]) -> OSStatus {
        if let operationHooks {
            return operationHooks.deleteItem(query)
        }
        return SecItemDelete(query as CFDictionary)
    }

    private func addItem(_ query: [String: Any]) -> OSStatus {
        if let operationHooks {
            return operationHooks.addItem(query)
        }
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func updateToken(
        matching query: [String: Any],
        data: Data,
        accessControl: SecAccessControl
    ) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl,
        ]
        let status: OSStatus = if let operationHooks {
            operationHooks.updateItem(query, attributes)
        } else {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw Self.error(for: .save, status: status)
        }
    }

    private func updateLocalFallbackToken(
        matching query: [String: Any],
        data: Data
    ) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: Self.localFallbackMarkerData,
        ]
        let status: OSStatus = if let operationHooks {
            operationHooks.updateItem(query, attributes)
        } else {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw Self.error(for: .save, status: status)
        }
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
