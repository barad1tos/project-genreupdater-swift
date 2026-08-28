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

/// Persisted minimal identity classification keyed by canonical Music.app database ID.
public struct LibraryInventoryIndex: Equatable, Sendable {
    public static let empty = Self(verifiedIdentities: [:])

    public let identitiesByID: [MusicDatabaseTrackID: MemberIdentity]

    public init?(identitiesByID: [MusicDatabaseTrackID: MemberIdentity]) {
        guard identitiesByID.allSatisfy({ $0.key == $0.value.databaseID }) else { return nil }
        self.init(verifiedIdentities: identitiesByID)
    }

    private init(verifiedIdentities: [MusicDatabaseTrackID: MemberIdentity]) {
        identitiesByID = verifiedIdentities
    }

    func admittedIDs(
        censusIDs: Set<MusicDatabaseTrackID>,
        observed: [MusicDatabaseTrackID: LibraryIdentityRow],
        scope: ProcessingScopeSnapshot
    ) -> Set<MusicDatabaseTrackID> {
        guard scope.source == .testArtists else { return censusIDs }

        var admitted = Set<MusicDatabaseTrackID>()
        for (databaseID, identity) in identitiesByID where censusIDs.contains(databaseID) {
            if ArtistAllowList.containsNormalized(
                artist: identity.artist,
                albumArtist: identity.albumArtist,
                in: scope.normalizedTestArtists
            ) {
                admitted.insert(databaseID)
            }
        }
        for (databaseID, identity) in observed where censusIDs.contains(databaseID) {
            if identity.matches(scope) {
                admitted.insert(databaseID)
            } else {
                admitted.remove(databaseID)
            }
        }
        return admitted
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
    public let inventory: LibraryInventoryIndex

    public init(
        scope: ProcessingScopeSnapshot,
        refresh: MetadataRefreshPolicy,
        previous: LibraryMirrorReference,
        inventory: LibraryInventoryIndex = .empty
    ) {
        self.scope = scope
        self.refresh = refresh
        self.previous = previous
        self.inventory = inventory
    }
}

extension LibraryObservationRequest {
    func identityLookupIDs(in censusIDs: [MusicDatabaseTrackID]) -> [MusicDatabaseTrackID] {
        guard scope.source == .testArtists else { return [] }
        switch refresh {
        case .force:
            return censusIDs
        case .fast, .membershipOnly:
            let classifiedIDs = Set(inventory.identitiesByID.keys)
            return censusIDs.filter { !classifiedIDs.contains($0) }
        }
    }

    func metadataLookupIDs(
        in censusIDs: [MusicDatabaseTrackID],
        admittedIDs: Set<MusicDatabaseTrackID>
    ) -> [MusicDatabaseTrackID] {
        switch refresh {
        case .fast:
            let previousIDs = Set(previous.tracksByID.keys)
            return censusIDs.filter { admittedIDs.contains($0) && !previousIDs.contains($0) }
        case .force:
            return censusIDs.filter(admittedIDs.contains)
        case .membershipOnly:
            return []
        }
    }

    func reportedIdentityIDs(
        identityLookupIDs: [MusicDatabaseTrackID],
        metadataLookupIDs: [MusicDatabaseTrackID]
    ) -> Set<MusicDatabaseTrackID> {
        scope.source == .fullLibrary ? Set(metadataLookupIDs) : Set(identityLookupIDs)
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

/// IDs requested and returned by minimal member-identity classification.
public struct IdentityCompleteness: Equatable, Sendable {
    public let requestedIDs: Set<MusicDatabaseTrackID>
    public let observedIDs: Set<MusicDatabaseTrackID>

    public var isComplete: Bool {
        requestedIDs == observedIDs
    }

    public init(
        requestedIDs: Set<MusicDatabaseTrackID>,
        observedIDs: Set<MusicDatabaseTrackID>
    ) {
        self.requestedIDs = requestedIDs
        self.observedIDs = observedIDs
    }
}

public enum LibraryObservationIssue: Equatable, Sendable {
    case identityUnobserved(databaseID: MusicDatabaseTrackID, detail: String)
    case metadataUnobserved(databaseID: MusicDatabaseTrackID, detail: String)
}

/// Generation-fenced library membership and processing scope for one observation.
public struct LibraryObservationEpoch: Equatable, Sendable {
    public let censusIDs: Set<MusicDatabaseTrackID>
    public let currentIDs: Set<MusicDatabaseTrackID>
    public let scope: ProcessingScopeSnapshot
    public let observedAt: Date
    public let generation: LibraryGeneration

    public init(
        censusIDs: Set<MusicDatabaseTrackID>,
        currentIDs: Set<MusicDatabaseTrackID>,
        scope: ProcessingScopeSnapshot,
        observedAt: Date,
        generation: LibraryGeneration
    ) {
        self.censusIDs = censusIDs
        self.currentIDs = currentIDs
        self.scope = scope
        self.observedAt = observedAt
        self.generation = generation
    }
}

/// Completeness evidence and issues reported by one library observation.
public struct LibraryObservationCoverage: Equatable, Sendable {
    public let membership: MembershipCompleteness
    public let identity: IdentityCompleteness
    public let metadata: MetadataCompleteness
    public let issues: [LibraryObservationIssue]

    public init(
        membership: MembershipCompleteness,
        identity: IdentityCompleteness,
        metadata: MetadataCompleteness,
        issues: [LibraryObservationIssue]
    ) {
        self.membership = membership
        self.identity = identity
        self.metadata = metadata
        self.issues = issues
    }
}

/// Minimal AppleScript identity row used only for processing-scope classification.
public struct LibraryIdentityRow: Equatable, Sendable {
    public let databaseID: MusicDatabaseTrackID
    public let artist: Observed<String>
    public let albumArtist: Observed<String>

    public init(
        databaseID: MusicDatabaseTrackID,
        artist: Observed<String>,
        albumArtist: Observed<String>
    ) {
        self.databaseID = databaseID
        self.artist = artist
        self.albumArtist = albumArtist
    }

    func matches(_ scope: ProcessingScopeSnapshot) -> Bool {
        guard scope.source == .testArtists else { return true }
        return ArtistAllowList.containsNormalized(
            artist: artist.value,
            albumArtist: albumArtist.value,
            in: scope.normalizedTestArtists
        )
    }

    var hasCompleteFields: Bool {
        artist.isObserved && albumArtist.isObserved
    }
}

extension Observed where Value == String {
    fileprivate var value: String? {
        guard case let .value(value) = self else { return nil }
        return value
    }
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

    func hasCompleteMetadata(for fieldSet: MirrorFieldSet) -> Bool {
        guard fieldSet == .processingV1 else { return false }
        return name.isObserved
            && artist.isObserved
            && album.isObserved
            && albumArtist.isObserved
            && genre.isObserved
            && editableYear.isObserved
            && releaseYear.isObserved
            && dateAdded.isObserved
            && lastModified.isObserved
            && status.isObserved
    }

    var identityRow: LibraryIdentityRow {
        LibraryIdentityRow(databaseID: databaseID, artist: artist, albumArtist: albumArtist)
    }
}

extension Observed {
    fileprivate var isObserved: Bool {
        switch self {
        case .value, .absent: true
        case .unobserved: false
        }
    }
}

/// One generation-fenced processing observation below the existing projection layer.
public struct LibraryObservation: Equatable, Sendable {
    public let tracks: [LibraryTrackRow]
    public let identities: [LibraryIdentityRow]
    /// Full Music database membership captured in the same generation as this observation.
    public let censusIDs: Set<MusicDatabaseTrackID>
    public let currentIDs: Set<MusicDatabaseTrackID>
    public let scope: ProcessingScopeSnapshot
    public let observedAt: Date
    public let membership: MembershipCompleteness
    public let identity: IdentityCompleteness
    public let metadata: MetadataCompleteness
    public let generation: LibraryGeneration
    public let issues: [LibraryObservationIssue]

    public init(
        tracks: [LibraryTrackRow],
        identities: [LibraryIdentityRow] = [],
        epoch: LibraryObservationEpoch,
        coverage: LibraryObservationCoverage
    ) {
        self.tracks = tracks
        self.identities = identities
        censusIDs = epoch.censusIDs
        currentIDs = epoch.currentIDs
        scope = epoch.scope
        observedAt = epoch.observedAt
        membership = coverage.membership
        identity = coverage.identity
        metadata = coverage.metadata
        generation = epoch.generation
        issues = coverage.issues
    }
}

enum MusicAppObservationError: Error, LocalizedError {
    case censusChanged
    case generationChanged(started: LibraryGeneration, ended: LibraryGeneration)
    case duplicateMetadata(MusicDatabaseTrackID)
    case duplicateIdentity(MusicDatabaseTrackID)
    case unexpectedMetadata(MusicDatabaseTrackID)
    case unexpectedIdentity(MusicDatabaseTrackID)
    case unresolvedMetadataIdentity

    var errorDescription: String? {
        switch self {
        case .censusChanged:
            "Music library census changed during metadata observation"
        case let .generationChanged(started, ended):
            "Music library generation changed during observation (\(started.rawValue) to \(ended.rawValue))"
        case let .duplicateMetadata(databaseID):
            "Metadata lookup returned database ID \(databaseID.rawValue) more than once"
        case let .duplicateIdentity(databaseID):
            "Identity lookup returned database ID \(databaseID.rawValue) more than once"
        case let .unexpectedMetadata(databaseID):
            "Metadata lookup returned unrequested database ID \(databaseID.rawValue)"
        case let .unexpectedIdentity(databaseID):
            "Identity lookup returned unrequested database ID \(databaseID.rawValue)"
        case .unresolvedMetadataIdentity:
            "Metadata lookup returned a track without a resolved AppleScript database ID"
        }
    }
}

/// Narrow read capability for generation-fenced processing observations.
public protocol MusicAppReading: Actor {
    func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation
}
