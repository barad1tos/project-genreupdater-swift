import Core
import Foundation
@testable import Services

extension LibrarySyncService {
    func detectObservation(forceMetadataRefresh: Bool = false) async throws -> SyncDetection {
        let state = try await prepareAttempt(captureAttemptInput(forceMetadataRefresh: forceMetadataRefresh))
        guard case let .prepared(detection) = state else {
            throw LibrarySyncObservationError.invalidObservation(detail: "synchronization was not prepared")
        }
        return detection
    }
}

struct ObservationTemplate: Sendable {
    let rows: [LibraryTrackRow]
    let censusIDs: Set<MusicDatabaseTrackID>
    let currentIDs: Set<MusicDatabaseTrackID>
    let membership: MembershipCompleteness
    let requestedIDs: Set<MusicDatabaseTrackID>
    let observedIDs: Set<MusicDatabaseTrackID>
    let generation: LibraryGeneration
}

enum SyncObservationTestError: Error, Equatable {
    case readFailed
    case commitFailed
}

actor DuplicateMetadataSource: ObservationSource {
    private let census: TrackIDCensus
    private let metadata: [Track]

    init(census: TrackIDCensus, metadata: [Track]) {
        self.census = census
        self.metadata = metadata
    }

    func fetchCensus() -> TrackIDCensus {
        census
    }

    func fetchIdentity(for _: [MusicDatabaseTrackID]) -> [LibraryIdentityRow] {
        metadata.compactMap(identityRow)
    }

    func fetchMetadata(for _: [MusicDatabaseTrackID]) -> [Track] {
        metadata
    }
}

actor StaticObservationSource: ObservationSource {
    private let census: TrackIDCensus
    private let metadata: [Track]

    init(census: TrackIDCensus, metadata: [Track]) {
        self.census = census
        self.metadata = metadata
    }

    func fetchCensus() -> TrackIDCensus {
        census
    }

    func fetchIdentity(for ids: [MusicDatabaseTrackID]) -> [LibraryIdentityRow] {
        let requested = Set(ids)
        return metadata.compactMap { track in
            guard track.databaseID.map(requested.contains) == true else { return nil }
            return identityRow(track)
        }
    }

    func fetchMetadata(for ids: [MusicDatabaseTrackID]) -> [Track] {
        let requested = Set(ids)
        return metadata.filter { track in
            track.databaseID.map(requested.contains) ?? false
        }
    }
}

private func identityRow(_ track: Track) -> LibraryIdentityRow? {
    guard let databaseID = track.databaseID else { return nil }
    return LibraryIdentityRow(
        databaseID: databaseID,
        artist: .value(track.artist),
        albumArtist: track.albumArtist.map(Observed.value) ?? .absent
    )
}

actor ObservationReader: MusicAppReading {
    private var templates: [ObservationTemplate]
    private let error: SyncObservationTestError?
    private(set) var requests: [LibraryObservationRequest] = []

    init(
        templates: [ObservationTemplate] = [],
        error: SyncObservationTestError? = nil
    ) {
        self.templates = templates
        self.error = error
    }

    func observe(_ request: LibraryObservationRequest) throws -> LibraryObservation {
        requests.append(request)
        if let error {
            throw error
        }
        let template = templates.count == 1 ? templates[0] : templates.removeFirst()
        let censusIDs = template.censusIDs.sorted { $0.rawValue < $1.rawValue }
        let identityLookups = request.identityLookupIDs(in: censusIDs)
        let metadataLookups = request.metadataLookupIDs(
            in: censusIDs,
            admittedIDs: template.currentIDs
        )
        let identityIDs = request.reportedIdentityIDs(
            identityLookupIDs: identityLookups,
            metadataLookupIDs: metadataLookups
        )
        let identities = template.rows.map(\.identityRow).filter { identityIDs.contains($0.databaseID) }
        let observedIdentityIDs = Set(identities.map(\.databaseID))
        return LibraryObservation(
            tracks: template.rows,
            identities: identities,
            epoch: LibraryObservationEpoch(
                censusIDs: template.censusIDs,
                currentIDs: template.currentIDs,
                scope: request.scope,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                generation: template.generation
            ),
            coverage: LibraryObservationCoverage(
                membership: template.membership,
                identity: IdentityCompleteness(
                    requestedIDs: identityIDs,
                    observedIDs: observedIdentityIDs
                ),
                metadata: MetadataCompleteness(
                    requestedIDs: template.requestedIDs,
                    observedIDs: template.observedIDs
                ),
                issues: []
            )
        )
    }
}

actor ObservationMirrorStore: TrackStateStore {
    struct ApplyCall: Sendable {
        let upserting: [Track]
        let membershipIDs: [MusicDatabaseTrackID]?
    }

    private(set) var stored: [Track]
    private(set) var presentIDs: Set<MusicDatabaseTrackID>
    private(set) var applyCalls: [ApplyCall] = []
    private let applyError: SyncObservationTestError?
    private var revision = MirrorRevision.initial
    private var certificates: [ScopeCertificate]

    init(
        stored: [Track],
        presentIDs: Set<MusicDatabaseTrackID>? = nil,
        applyError: SyncObservationTestError? = nil
    ) {
        self.stored = stored
        self.presentIDs = presentIDs ?? Set(stored.compactMap { track in
            guard let databaseID = track.databaseID, track.id == databaseID.rawValue else { return nil }
            return databaseID
        })
        self.applyError = applyError
        if let inventory = try? replacementInventory(for: stored),
           let certificate = try? scopeCertificate(
               revision: .initial,
               inventoryChange: inventory,
               trackIDs: stored.compactMap(\.databaseID),
               observedAt: Date(timeIntervalSince1970: 1_800_000_000)
           ) {
            certificates = [certificate]
        } else {
            certificates = []
        }
    }

    func initialize() async throws {
        // The test provides initialized mirror state and does not exercise initialization persistence.
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try mirrorSnapshot(
            revision: revision,
            tracks: stored,
            presentIDs: presentIDs,
            certificates: certificates
        )
    }

    @discardableResult
    func commitMirror(_ update: MirrorCommit) async throws -> MirrorCommitResult {
        applyCalls.append(ApplyCall(
            upserting: update.upserts,
            membershipIDs: inventoryIDs(update.inventoryChange)
        ))
        if let applyError {
            throw applyError
        }
        guard update.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: update.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()

        switch update.certificates {
        case .preserve:
            break
        case .invalidate:
            certificates = []
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        }

        if let replacementIDs = inventoryIDs(update.inventoryChange) {
            presentIDs = Set(replacementIDs)
        }
        applyInventory(update.inventoryChange, to: &stored)
        for track in update.upserts {
            if let index = stored.firstIndex(where: { $0.id == track.id }) {
                stored[index] = track
            } else {
                stored.append(track)
            }
        }
        stored.sort { $0.id < $1.id }
        revision = nextRevision
        return try MirrorCommitResult(
            revision: revision,
            snapshot: mirrorSnapshot(
                revision: revision,
                tracks: stored,
                presentIDs: presentIDs,
                certificates: certificates
            )
        )
    }

    func getTrack(byID id: String) async throws -> Track? {
        stored.first { $0.id == id }
    }

    func commitAppliedChange(_: ChangeLogEntry) async throws -> MirrorRevision {
        // The test exercises mirror reconciliation, not change-log persistence.
        revision
    }
    func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }
    func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID _: UUID
    ) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }

    func getUnprocessedTracks() async throws -> [Track] {
        stored
    }

    func trackCount() async throws -> Int {
        stored.count
    }
}
