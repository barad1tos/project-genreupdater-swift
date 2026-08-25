import Core
import Foundation

/// Acquires Music.app's canonical writable identity and authoritative metadata.
public protocol MusicAppIdentifying: Actor {
    /// Returns canonical Music.app tracks for the normalized artist scope.
    /// An empty scope reads the full library.
    func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Core.Track]
}

enum MusicAppIdentityError: Error, LocalizedError, Sendable, Equatable {
    case unresolvedMetadataIdentity
    case unexpectedMetadata(MusicDatabaseTrackID)
    case conflictingMetadata(MusicDatabaseTrackID)

    var errorDescription: String? {
        switch self {
        case .unresolvedMetadataIdentity:
            "Music.app returned metadata without a canonical database ID"
        case let .unexpectedMetadata(databaseID):
            "Music.app returned unexpected metadata for database ID \(databaseID.rawValue)"
        case let .conflictingMetadata(databaseID):
            "Music.app returned conflicting metadata for database ID \(databaseID.rawValue)"
        }
    }
}
