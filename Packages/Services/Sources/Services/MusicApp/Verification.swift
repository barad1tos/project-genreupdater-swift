import Core
import Foundation

/// Targeted canonical metadata reads used to prepare, verify, or recover Music.app writes.
public protocol MusicAppVerifying: Actor {
    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track]
}

/// Indicates that a targeted Music.app read returned identity evidence outside its request contract.
enum MusicAppVerificationError: Error, Equatable, LocalizedError {
    case unresolvedMetadataIdentity
    case unexpectedMetadata(MusicDatabaseTrackID)
    case duplicateMetadata(MusicDatabaseTrackID)

    var errorDescription: String? {
        switch self {
        case .unresolvedMetadataIdentity:
            "Targeted metadata lookup returned a track without a Music database ID"
        case let .unexpectedMetadata(databaseID):
            "Targeted metadata lookup returned unrequested database ID \(databaseID.rawValue)"
        case let .duplicateMetadata(databaseID):
            "Targeted metadata lookup returned database ID \(databaseID.rawValue) more than once"
        }
    }
}
