import Core
import Foundation
@testable import Services

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

    func fetchMetadata(for ids: [MusicDatabaseTrackID]) -> [Track] {
        let requested = Set(ids)
        return metadata.filter { track in
            track.databaseID.map(requested.contains) ?? false
        }
    }
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
        return LibraryObservation(
            tracks: template.rows,
            censusIDs: template.censusIDs,
            currentIDs: template.currentIDs,
            scope: request.scope,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            membership: template.membership,
            metadata: MetadataCompleteness(
                requestedIDs: template.requestedIDs,
                observedIDs: template.observedIDs
            ),
            generation: template.generation,
            issues: []
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
        if let membership = try? replacementMembership(for: stored),
           let certificate = try? scopeCertificate(
               revision: .initial,
               membershipChange: membership,
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

    func loadAllTracks() async throws -> [Track] {
        stored
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
            membershipIDs: membershipIDs(update.membershipChange)
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

        if let replacementIDs = membershipIDs(update.membershipChange) {
            presentIDs = Set(replacementIDs)
        }
        applyMembership(update.membershipChange, to: &stored)
        for track in update.upserts {
            if let index = stored.firstIndex(where: { $0.id == track.id }) {
                stored[index] = track
            } else {
                stored.append(track)
            }
        }
        stored.sort { $0.id < $1.id }
        revision = nextRevision
        return MirrorCommitResult(revision: revision)
    }

    func getTrack(byID id: String) async throws -> Track? {
        stored.first { $0.id == id }
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // The test exercises mirror reconciliation, not change-log persistence.
    }

    func getUnprocessedTracks() async throws -> [Track] {
        stored
    }

    func trackCount() async throws -> Int {
        stored.count
    }
}
