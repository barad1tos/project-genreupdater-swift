import Foundation
import SwiftData
@testable import Core
@testable import Services

func presentIDs(in container: ModelContainer) throws -> [MusicDatabaseTrackID] {
    let context = ModelContext(container)
    let members = try context.fetch(FetchDescriptor<PersistedLibraryMember>(
        predicate: #Predicate { $0.isPresent },
        sortBy: [SortDescriptor(\.databaseID)]
    ))
    return members.compactMap { MusicDatabaseTrackID(rawValue: $0.databaseID) }
}

extension TrackStateStore {
    func seedMirror(_ tracks: [Track]) async throws {
        let revision = try await loadMirrorSnapshot().revision
        let canonicalTracks = tracks.map { track in
            var canonical = track
            canonical.appleScriptID = canonical.id
            return canonical
        }
        let membership = try replacementMembership(for: canonicalTracks)
        let nextRevision = try revision.advanced()
        try await commitMirror(MirrorCommit(
            baseRevision: revision,
            observation: ObservationID(),
            membershipChange: membership,
            repairs: [],
            upserts: canonicalTracks,
            certificates: .replace(scopeCertificate(
                revision: nextRevision,
                membershipChange: membership,
                trackIDs: canonicalTracks.compactMap(\.databaseID)
            ))
        ))
    }
}

func replacementMembership(
    for tracks: [Track],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> MembershipChange {
    try replacementMembership(
        for: tracks.compactMap(\.databaseID),
        observedAt: observedAt
    )
}

func replacementMembership(
    for ids: [MusicDatabaseTrackID],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> MembershipChange {
    try .replace(stamp: MembershipFingerprint.make(ids: ids), ids: ids, observedAt: observedAt)
}

func mirrorSnapshot(
    revision: MirrorRevision,
    tracks: [Track],
    presentIDs: Set<MusicDatabaseTrackID>? = nil,
    certificates: [ScopeCertificate] = []
) throws -> TrackMirrorSnapshot {
    let presentTracks = tracks.filter { track in
        guard let databaseID = track.databaseID else { return false }
        return track.id == databaseID.rawValue
    }
    let membership = presentIDs ?? Set(presentTracks.compactMap(\.databaseID))
    return try TrackMirrorSnapshot(
        revision: revision,
        membershipStamp: MembershipFingerprint.make(ids: Array(membership)),
        presentIDs: membership,
        presentTracks: presentTracks,
        repairCandidates: tracks.filter { !presentTracks.contains($0) },
        certificates: certificates
    )
}

func scopeCertificate(
    revision: MirrorRevision,
    membershipChange: MembershipChange,
    testArtists: [String] = [],
    trackIDs: [MusicDatabaseTrackID],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> ScopeCertificate {
    guard case let .replace(membership, _, _) = membershipChange else {
        preconditionFailure("A scope certificate requires replacement membership")
    }
    let fingerprint = try MembershipFingerprint.make(ids: trackIDs).fingerprint
    return ScopeCertificate(
        id: UUID(),
        revision: revision,
        membership: membership,
        testArtists: testArtists,
        fieldSet: .processingV1,
        evidence: ScopeEvidence(
            requestedFingerprint: fingerprint,
            observedFingerprint: fingerprint,
            trackCount: trackIDs.count
        ),
        observedAt: observedAt
    )
}

func membershipIDs(_ change: MembershipChange) -> [MusicDatabaseTrackID]? {
    guard case let .replace(_, ids, _) = change else { return nil }
    return ids
}

func applyMembership(_ change: MembershipChange, to tracks: inout [Track]) {
    guard let ids = membershipIDs(change) else { return }
    let presentIDs = Set(ids.map(\.rawValue))
    tracks.removeAll { track in
        guard let databaseID = track.databaseID, track.id == databaseID.rawValue else { return false }
        return !presentIDs.contains(track.id)
    }
}
