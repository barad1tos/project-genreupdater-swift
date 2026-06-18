// KeychainError.swift — Keychain save results and error values.

import Foundation
import Security

/// Result of saving a token to the Keychain.
public enum KeychainSaveResult: Sendable, Equatable {
    /// The token was saved with local user presence protection.
    case protected
    /// The token was saved in a local fallback for unsigned development builds.
    case localFallback
}

enum KeychainOperation {
    case save
    case retrieve
    case delete
}

/// Errors from Keychain operations.
public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    /// Creating the access-control policy for a protected token failed.
    case accessControlCreationFailed(String?)
    /// Local authentication was unavailable, cancelled, or failed.
    case authenticationFailed(OSStatus)
    /// A legacy token item exists without the current local-authentication policy.
    case unprotectedItemRequiresResave
    /// The token input was empty after trimming whitespace.
    case emptyToken
    /// The stored token item could not be decoded into a non-empty UTF-8 string.
    case invalidTokenData
    /// `SecItemAdd` or `SecItemUpdate` returned a non-success status.
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
        case .emptyToken:
            "Keychain token cannot be empty"
        case .invalidTokenData:
            "Stored Keychain token data is invalid"
        case let .saveFailed(status):
            if status == errSecMissingEntitlement {
                """
                Keychain entitlement is missing. Run a signed app bundle with Keychain entitlements before \
                saving API tokens.
                """
            } else {
                "Keychain save failed with OSStatus \(status)"
            }
        case let .retrieveFailed(status):
            "Keychain retrieve failed with OSStatus \(status)"
        case let .deleteFailed(status):
            "Keychain delete failed with OSStatus \(status)"
        }
    }
}
