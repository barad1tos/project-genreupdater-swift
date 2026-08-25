import Core
import Foundation

/// A writable metadata field exposed by Music.app.
public enum MusicTrackProperty: String, Sendable {
    case genre
    case year
    case name
    case album
    case artist
    case albumArtist = "album_artist"

    init(changeType: ChangeType) {
        self = switch changeType {
        case .genreUpdate: .genre
        case .yearUpdate, .yearRevert: .year
        case .trackCleaning: .name
        case .albumCleaning: .album
        case .artistRename: .artist
        }
    }

    func currentValue(in track: Track) -> String? {
        switch self {
        case .genre:
            track.genre ?? ""
        case .year:
            track.year.map(String.init) ?? ""
        case .name:
            track.name
        case .album:
            track.album
        case .artist:
            track.artist
        case .albumArtist:
            track.albumArtist ?? ""
        }
    }

    func comparisonValue(_ value: String?) -> String? {
        guard self == .year else { return value }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        guard let year = Int(trimmed) else { return trimmed }
        return MusicAppYear.normalized(year).map(String.init)
    }
}

/// One typed property mutation sent to Music.app.
public struct MusicTrackUpdate: Equatable, Sendable {
    public let databaseID: MusicDatabaseTrackID
    public let property: MusicTrackProperty
    public let value: String

    /// Creates a mutation that can be dispatched by the bundled Music.app writers.
    ///
    /// Year values must parse as integers and satisfy `MusicAppYear.isWritable`; validation happens before dispatch.
    /// - Throws: An error when a year value violates that contract.
    public init(databaseID: MusicDatabaseTrackID, property: MusicTrackProperty, value: String) throws {
        try self.init(databaseID: databaseID, property: property, value: value, at: Date())
    }

    init(
        databaseID: MusicDatabaseTrackID,
        property: MusicTrackProperty,
        value: String,
        at date: Date
    ) throws {
        if property == .year {
            guard let year = Int(value), MusicAppYear.isWritable(year, at: date) else {
                throw MusicTrackUpdateError.invalidYear
            }
        }
        self.databaseID = databaseID
        self.property = property
        self.value = value
    }
}

enum MusicTrackUpdateError: Error, LocalizedError, Sendable, Equatable {
    case invalidYear

    var errorDescription: String? {
        switch self {
        case .invalidYear:
            "Year update must be 0 or within the writable Music.app range"
        }
    }
}

/// Result of a single Music.app metadata mutation.
public enum MusicWriteResult: Sendable, Equatable {
    case changed
    case noChange
}

/// A batch may have landed but its final metadata state could not be verified.
struct MusicBatchVerificationError: Error, LocalizedError, Sendable, Equatable {
    let updateCount: Int
    let failedCount: Int?
    let reason: String

    var errorDescription: String? {
        if let failedCount {
            return "Batch verification failed for \(failedCount) of \(updateCount) updates: \(reason)"
        }
        return "Batch verification failed for \(updateCount) updates: \(reason)"
    }
}

/// Records that a Music.app mutation may have been dispatched.
public typealias WriteAttemptHook = @Sendable () async throws -> Void

/// Preserves both a failed write and the failed attempt checkpoint that followed it.
struct WriteAttemptFailure: Error {
    let writeError: any Error
    let checkpointError: any Error
}

/// Grants physical metadata mutation rights in Music.app.
public protocol MusicAppMutating: Actor {
    /// Applies one mutation.
    /// - Parameter onAttempt: Invoke exactly once when the mutation may have reached Music.app, before reporting its
    ///   outcome. Do not invoke it for confirmed pre-dispatch failure or cancellation. Propagate hook failures without
    ///   discarding write uncertainty.
    func update(
        _ update: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult

    /// Applies a mutation batch.
    /// - Parameter onAttempt: Invoke exactly once when the batch may have reached Music.app, before reporting its
    ///   outcome. Do not invoke it for confirmed pre-dispatch failure or cancellation. Propagate hook failures without
    ///   discarding write uncertainty.
    func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws
}
