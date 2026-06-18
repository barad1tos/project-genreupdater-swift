// DiscogsClient+Keychain.swift — Keychain persistence for Discogs credentials.

import Core

extension DiscogsClient {
    static var legacyKeychainService: String {
        "GenreUpdater-Discogs"
    }
    static var legacyKeychainAccount: String {
        "pat"
    }

    /// Saves a Discogs Personal Access Token to the Keychain.
    ///
    /// - Parameter token: The PAT to store.
    /// - Throws: `KeychainError.emptyToken` for blank input, access-control and authentication
    ///   errors when protected storage cannot be used, or `KeychainError.saveFailed` on Keychain
    ///   add or replacement failure.
    public static func saveToken(_ token: String) throws -> KeychainSaveResult {
        let keychain = KeychainHelper()
        return try keychain.save(
            token: token,
            service: keychainService,
            account: keychainAccount
        )
    }

    /// Retrieves the saved Discogs token, migrating the previous Settings key if needed.
    ///
    /// - Returns: The stored token string, or `nil` if neither keychain item exists.
    /// - Throws: `KeychainError` if either the current item or legacy migration cannot be read safely.
    public static func retrieveSavedToken() throws -> String? {
        try retrieveSavedToken(keychain: KeychainHelper())
    }

    /// Deletes saved Discogs tokens from both current and previous Settings keychain locations.
    ///
    /// - Throws: `KeychainError` if the current or legacy item cannot be deleted safely.
    public static func deleteSavedToken() throws {
        try deleteSavedToken(keychain: KeychainHelper())
    }

    static func retrieveSavedToken(keychain: KeychainHelper) throws -> String? {
        if let token = try keychain.retrieve(
            service: keychainService,
            account: keychainAccount
        ) {
            return token
        }

        guard let legacyToken = try keychain.retrieve(
            service: legacyKeychainService,
            account: legacyKeychainAccount
        ) else {
            return nil
        }

        try keychain.save(
            token: legacyToken,
            service: keychainService,
            account: keychainAccount
        )
        do {
            try keychain.delete(
                service: legacyKeychainService,
                account: legacyKeychainAccount
            )
        } catch {
            AppLogger.api.warning(
                "Migrated Discogs token but failed to delete legacy Keychain item: \(error.localizedDescription, privacy: .public)"
            )
        }
        return legacyToken
    }

    static func deleteSavedToken(keychain: KeychainHelper) throws {
        try keychain.delete(
            service: keychainService,
            account: keychainAccount
        )
        try keychain.delete(
            service: legacyKeychainService,
            account: legacyKeychainAccount
        )
    }
}
