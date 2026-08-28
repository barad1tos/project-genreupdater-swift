import Core
import Foundation
import Testing
@testable import Services

actor MusicAppTestObserver: MusicAppReading {
    private let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func observe(_ request: LibraryObservationRequest) throws -> LibraryObservation {
        let generation = try #require(LibraryGeneration(sourceValue: "root-test"))
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            track.databaseID.map { ($0, track) }
        })
        let censusIDs = Set(tracksByID.keys)
        let identitiesByID = Dictionary(uniqueKeysWithValues: tracksByID.map { databaseID, track in
            (databaseID, row(track, databaseID: databaseID).identityRow)
        })
        let requestedIdentityIDs = identityIDs(censusIDs: censusIDs, request: request)
        let observedIdentities = identitiesByID.filter { requestedIdentityIDs.contains($0.key) }
        let currentIDs = request.inventory.admittedIDs(
            censusIDs: censusIDs,
            observed: observedIdentities,
            scope: request.scope
        )
        let previousIDs = Set(request.previous.tracksByID.keys)
        let requestedIDs: Set<MusicDatabaseTrackID> = switch request.refresh {
        case .fast:
            currentIDs.subtracting(previousIDs)
        case .force:
            currentIDs
        case .membershipOnly:
            []
        }
        let rows = requestedIDs.sorted { $0.rawValue < $1.rawValue }.compactMap { databaseID in
            tracksByID[databaseID].map { row($0, databaseID: databaseID) }
        }
        let identities = request.scope.source == .fullLibrary
            ? rows.map(\.identityRow)
            : observedIdentities.values.sorted { $0.databaseID.rawValue < $1.databaseID.rawValue }
        let reportedIdentityIDs = request.scope.source == .fullLibrary ? requestedIDs : requestedIdentityIDs
        return LibraryObservation(
            tracks: rows,
            identities: identities,
            censusIDs: censusIDs,
            currentIDs: currentIDs,
            scope: request.scope,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            membership: request.scope.source == .fullLibrary ? .full : .scoped(unobservedIDs: []),
            identity: IdentityCompleteness(
                requestedIDs: reportedIdentityIDs,
                observedIDs: Set(identities.map(\.databaseID))
            ),
            metadata: MetadataCompleteness(requestedIDs: requestedIDs, observedIDs: Set(rows.map(\.databaseID))),
            generation: generation,
            issues: []
        )
    }

    private func identityIDs(
        censusIDs: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) -> Set<MusicDatabaseTrackID> {
        guard request.scope.source == .testArtists else { return [] }
        switch request.refresh {
        case .force:
            return censusIDs
        case .fast, .membershipOnly:
            return censusIDs.subtracting(request.inventory.identitiesByID.keys)
        }
    }

    private func row(_ track: Track, databaseID: MusicDatabaseTrackID) -> LibraryTrackRow {
        LibraryTrackRow(
            databaseID: databaseID,
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: .value(track.name),
                    artist: .value(track.artist),
                    album: .value(track.album),
                    albumArtist: track.albumArtist.map(Observed.value) ?? .absent
                ),
                genre: track.genre.map(Observed.value) ?? .absent,
                editableYear: track.year.map(Observed.value) ?? .absent,
                releaseYear: track.releaseYear.map(Observed.value) ?? .absent,
                dateAdded: track.dateAdded.map(Observed.value) ?? .absent,
                lastModified: track.lastModified.map(Observed.value) ?? .absent,
                status: track.trackStatus.map(Observed.value) ?? .absent
            )
        )
    }
}

actor PreviewAdmissionStore: TrackStateStore {
    private let snapshot: TrackMirrorSnapshot
    private var mirrorLoads = 0
    private var allTrackLoads = 0

    init(track: Track, testArtists: [String], observedAt: Date) throws {
        guard let databaseID = track.databaseID else { throw PreviewStoreError.nonCanonicalTrack }
        let membership = try MembershipFingerprint.make(ids: [databaseID])
        let certificate = ScopeCertificate(
            id: UUID(),
            revision: .initial,
            membership: membership,
            testArtists: testArtists,
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: membership.fingerprint,
                observedFingerprint: membership.fingerprint,
                trackCount: 1
            ),
            observedAt: observedAt
        )
        snapshot = TrackMirrorSnapshot(
            revision: .initial,
            membershipStamp: membership,
            presentIDs: [databaseID],
            memberIdentities: testIdentityIndex(for: [track], observedAt: observedAt),
            presentTracks: [track],
            repairCandidates: [],
            certificates: [certificate]
        )
    }

    func initialize() async throws {
        throw PreviewStoreError.unexpectedInitialize
    }

    func loadAllTracks() async throws -> [Track] {
        allTrackLoads += 1
        throw PreviewStoreError.unexpectedLoadAll
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        mirrorLoads += 1
        return snapshot
    }

    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        try MirrorCommitResult(revision: commit.baseRevision.advanced())
    }

    func getTrack(byID _: String) async throws -> Track? {
        nil
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        throw PreviewStoreError.unexpectedPersist
    }

    func getUnprocessedTracks() async throws -> [Track] {
        []
    }

    func trackCount() async throws -> Int {
        snapshot.presentTracks.count
    }

    func mirrorLoadCount() -> Int {
        mirrorLoads
    }

    func allTrackLoadTotal() -> Int {
        allTrackLoads
    }
}

private enum PreviewStoreError: Error {
    case nonCanonicalTrack
    case unexpectedInitialize
    case unexpectedLoadAll
    case unexpectedPersist
}

struct RunConfigSnapshot: Sendable {
    let libraryPaths: [String]
    let testArtists: [[String]]
    let verificationDays: [Int]
}

actor RunConfigProbe {
    private var libraryPaths: [String] = []
    private var testArtists: [[String]] = []
    private var verificationDays: [Int] = []

    func recordScriptConfig(_ configuration: AppConfiguration) {
        libraryPaths.append(configuration.paths.musicLibraryPath)
        testArtists.append(configuration.development.testArtists)
    }

    func recordPendingConfig(_ configuration: AppConfiguration) {
        verificationDays.append(configuration.processing.pendingVerificationIntervalDays)
    }

    func snapshot() -> RunConfigSnapshot {
        RunConfigSnapshot(
            libraryPaths: libraryPaths,
            testArtists: testArtists,
            verificationDays: verificationDays
        )
    }
}

actor PreviewScriptClient: MusicAppIdentifying, MusicAppMutating, MusicAppVerifying {
    private let tracks: [Track]
    private var fetchedIdentityScopes: [[String]] = []

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        let requestedIDs = Set(databaseIDs.map(\.rawValue))
        return tracks.filter { requestedIDs.contains($0.databaseID?.rawValue ?? $0.id) }
    }

    func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Track] {
        fetchedIdentityScopes.append(artists)
        return ArtistAllowList.filter(tracks, allowedArtists: artists)
    }

    func update(
        _: MusicTrackUpdate,
        onAttempt _: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        throw PreviewScriptError.unexpectedWrite
    }

    func update(
        _: [MusicTrackUpdate],
        onAttempt _: @escaping WriteAttemptHook
    ) async throws {
        throw PreviewScriptError.unexpectedWrite
    }

    func identityScopes() -> [[String]] {
        fetchedIdentityScopes
    }
}

enum PreviewScriptError: Error {
    case unexpectedWrite
}

func musicKitTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album")
}

func appleScriptTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album", appleScriptID: id)
}

actor PreviewProducerProbe {
    nonisolated let producedAt = Date(timeIntervalSince1970: 1_800_000_100)
    private let track = Track(
        id: "track-1",
        name: "Preview Track",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2000,
        trackStatus: "purchased"
    )
    private let albumPeer = Track(
        id: "album-peer",
        name: "Album Peer",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2001,
        trackStatus: "purchased"
    )
    private var loadCallCount = 0
    private var refreshInputIDs: [String] = []
    private var refreshScope: ProcessingScopeSnapshot?
    private var albumContextInputIDs: [String] = []
    private var determinedTrackID: String?
    private var determinedAlbumIDs: [String] = []
    private var determinedArtistIDs: [String] = []
    private var options: UpdateOptions?
    private var savedPlan: FixPlan?
    private var savedDecision: FixPlanReviewDecision?

    func loadTracks() -> [Track] {
        loadCallCount += 1
        return [track]
    }

    func refreshWriteIdentity(for tracks: [Track], scope: ProcessingScopeSnapshot) {
        refreshInputIDs = tracks.map(\.id)
        refreshScope = scope
    }

    func albumContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        albumContextInputIDs = tracks.map(\.id)
        return [track.id: [albumPeer]]
    }

    func determineTrackChanges(
        track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) throws -> [ProposedChange] {
        determinedTrackID = track.id
        determinedAlbumIDs = albumTracks.map(\.id)
        determinedArtistIDs = artistTracks.map(\.id)
        self.options = options
        return [
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "2000",
                newValue: "2001",
                confidence: options.minConfidence,
                source: "test"
            )
        ]
    }

    func savePlan(_ plan: FixPlan, initialDecision: FixPlanReviewDecision) {
        savedPlan = plan
        savedDecision = initialDecision
    }

    func snapshot() -> PreviewProducerProbeSnapshot {
        PreviewProducerProbeSnapshot(
            loadedCount: loadCallCount,
            refreshInputIDs: refreshInputIDs,
            refreshScope: refreshScope,
            albumContextInputIDs: albumContextInputIDs,
            determinedTrackID: determinedTrackID,
            determinedAlbumIDs: determinedAlbumIDs,
            determinedArtistIDs: determinedArtistIDs,
            options: options,
            savedPlan: savedPlan,
            savedDecision: savedDecision
        )
    }
}

struct PreviewProducerProbeSnapshot {
    let loadedCount: Int
    let refreshInputIDs: [String]
    let refreshScope: ProcessingScopeSnapshot?
    let albumContextInputIDs: [String]
    let determinedTrackID: String?
    let determinedAlbumIDs: [String]
    let determinedArtistIDs: [String]
    let options: UpdateOptions?
    let savedPlan: FixPlan?
    let savedDecision: FixPlanReviewDecision?
}
