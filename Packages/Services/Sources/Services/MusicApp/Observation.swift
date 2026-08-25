import Core
import Foundation

/// A source fact that distinguishes authoritative absence from an omitted observation.
public enum Observed<Value: Sendable>: Sendable {
    case value(Value)
    case absent
    case unobserved(reason: String)
}

extension Observed: Equatable where Value: Equatable {}

/// Evidence identifying one stable Music library observation epoch.
public struct LibraryGeneration: Equatable, Hashable, Sendable {
    public let rawValue: String

    init?(sourceValue: String) {
        guard !sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        rawValue = sourceValue
    }
}

public enum MetadataRefreshPolicy: Equatable, Sendable {
    case fast
    case force
    case membershipOnly
}

/// Previously verified processing metadata keyed by resolved database identity.
public struct LibraryMirrorIndex: Equatable, Sendable {
    public let tracksByID: [MusicDatabaseTrackID: Track]

    public init?(tracksByID: [MusicDatabaseTrackID: Track]) {
        guard tracksByID.allSatisfy({ databaseID, track in
            track.databaseID == databaseID && track.id == databaseID.rawValue
        }) else {
            return nil
        }
        self.tracksByID = tracksByID
    }
}

public enum LibraryMirrorReference: Equatable, Sendable {
    case initial
    case verified(LibraryMirrorIndex)

    var tracksByID: [MusicDatabaseTrackID: Track] {
        switch self {
        case .initial:
            [:]
        case let .verified(mirror):
            mirror.tracksByID
        }
    }
}

public struct LibraryObservationRequest: Equatable, Sendable {
    public let scope: ProcessingScopeSnapshot
    public let refresh: MetadataRefreshPolicy
    public let previous: LibraryMirrorReference

    public init(
        scope: ProcessingScopeSnapshot,
        refresh: MetadataRefreshPolicy,
        previous: LibraryMirrorReference
    ) {
        self.scope = scope
        self.refresh = refresh
        self.previous = previous
    }
}

/// Completeness of the current membership set, independent of metadata lookup coverage.
public enum MembershipCompleteness: Equatable, Sendable {
    case full
    case scoped(unobservedIDs: Set<MusicDatabaseTrackID>)
}

/// IDs requested and returned by the metadata lookup for this observation.
public struct MetadataCompleteness: Equatable, Sendable {
    public let requestedIDs: Set<MusicDatabaseTrackID>
    public let observedIDs: Set<MusicDatabaseTrackID>

    public var isComplete: Bool {
        requestedIDs == observedIDs
    }
}

public enum LibraryObservationIssue: Equatable, Sendable {
    case metadataUnobserved(databaseID: MusicDatabaseTrackID, detail: String)
}

public struct LibraryTrackText: Equatable, Sendable {
    public let name: Observed<String>
    public let artist: Observed<String>
    public let album: Observed<String>
    public let albumArtist: Observed<String>
}

public struct LibraryTrackMetadata: Equatable, Sendable {
    public let text: LibraryTrackText
    public let genre: Observed<String>
    public let editableYear: Observed<Int>
    public let releaseYear: Observed<Int>
    public let dateAdded: Observed<Date>
    public let lastModified: Observed<Date>
    public let status: Observed<String>
}

/// One normalized AppleScript metadata row keyed by its database identity.
public struct LibraryTrackRow: Equatable, Sendable {
    public let databaseID: MusicDatabaseTrackID
    public let metadata: LibraryTrackMetadata

    public var name: Observed<String> {
        metadata.text.name
    }
    public var artist: Observed<String> {
        metadata.text.artist
    }
    public var album: Observed<String> {
        metadata.text.album
    }
    public var albumArtist: Observed<String> {
        metadata.text.albumArtist
    }
    public var genre: Observed<String> {
        metadata.genre
    }
    public var editableYear: Observed<Int> {
        metadata.editableYear
    }
    public var releaseYear: Observed<Int> {
        metadata.releaseYear
    }
    public var dateAdded: Observed<Date> {
        metadata.dateAdded
    }
    public var lastModified: Observed<Date> {
        metadata.lastModified
    }
    public var status: Observed<String> {
        metadata.status
    }

    func matches(_ scope: ProcessingScopeSnapshot) -> Bool {
        guard scope.source == .testArtists else { return true }
        let effectiveArtist: String? = switch albumArtist {
        case let .value(albumArtist):
            ArtistAllowList.normalizedName(albumArtist)
        case .absent:
            if case let .value(artist) = artist {
                ArtistAllowList.normalizedName(artist)
            } else {
                nil
            }
        case .unobserved:
            nil
        }
        guard let effectiveArtist else { return false }
        return ArtistAllowList.containsNormalized(effectiveArtist, in: scope.normalizedTestArtists)
    }
}

/// One generation-fenced processing observation below the existing projection layer.
public struct LibraryObservation: Equatable, Sendable {
    public let tracks: [LibraryTrackRow]
    /// Full Music database membership captured in the same generation as this observation.
    public let censusIDs: Set<MusicDatabaseTrackID>
    public let currentIDs: Set<MusicDatabaseTrackID>
    public let scope: ProcessingScopeSnapshot
    public let observedAt: Date
    public let membership: MembershipCompleteness
    public let metadata: MetadataCompleteness
    public let generation: LibraryGeneration
    public let issues: [LibraryObservationIssue]
}

enum MusicAppObservationError: Error, LocalizedError {
    case censusChanged
    case generationChanged(started: LibraryGeneration, ended: LibraryGeneration)
    case duplicateMetadata(MusicDatabaseTrackID)
    case unexpectedMetadata(MusicDatabaseTrackID)
    case unresolvedMetadataIdentity

    var errorDescription: String? {
        switch self {
        case .censusChanged:
            "Music library census changed during metadata observation"
        case let .generationChanged(started, ended):
            "Music library generation changed during observation (\(started.rawValue) to \(ended.rawValue))"
        case let .duplicateMetadata(databaseID):
            "Metadata lookup returned database ID \(databaseID.rawValue) more than once"
        case let .unexpectedMetadata(databaseID):
            "Metadata lookup returned unrequested database ID \(databaseID.rawValue)"
        case .unresolvedMetadataIdentity:
            "Metadata lookup returned a track without a resolved AppleScript database ID"
        }
    }
}

/// Narrow read capability for generation-fenced processing observations.
public protocol MusicAppReading: Actor {
    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation
}
