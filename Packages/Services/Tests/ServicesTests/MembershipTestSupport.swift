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
        let inventory = try replacementInventory(for: canonicalTracks)
        let nextRevision = try revision.advanced()
        try await commitMirror(MirrorCommit(
            baseRevision: revision,
            observation: ObservationID(),
            inventoryChange: inventory,
            repairs: [],
            upserts: canonicalTracks,
            certificates: .replace(scopeCertificate(
                revision: nextRevision,
                inventoryChange: inventory,
                trackIDs: canonicalTracks.compactMap(\.databaseID)
            ))
        ))
    }
}

func replacementInventory(
    for tracks: [Track],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> InventoryChange {
    let ids = tracks.compactMap(\.databaseID)
    return try .replace(
        stamp: MembershipFingerprint.make(ids: ids),
        ids: ids,
        identities: memberIdentities(for: tracks, observedAt: observedAt),
        observedAt: observedAt
    )
}

func replacementInventory(
    for ids: [MusicDatabaseTrackID],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> InventoryChange {
    try .replace(
        stamp: MembershipFingerprint.make(ids: ids),
        ids: ids,
        identities: [],
        observedAt: observedAt
    )
}

func mirrorSnapshot(
    revision: MirrorRevision,
    tracks: [Track],
    presentIDs: Set<MusicDatabaseTrackID>? = nil,
    memberIdentities explicitIdentities: [MusicDatabaseTrackID: MemberIdentity]? = nil,
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
        memberIdentities: explicitIdentities ?? memberIdentityIndex(for: tracks),
        presentTracks: presentTracks,
        repairCandidates: tracks.filter { !presentTracks.contains($0) },
        certificates: certificates
    )
}

private func memberIdentities(
    for tracks: [Track],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> [MemberIdentity] {
    tracks.compactMap { track in
        guard let databaseID = track.databaseID else { return nil }
        return MemberIdentity(
            databaseID: databaseID,
            artist: track.artist,
            albumArtist: track.albumArtist,
            observedAt: observedAt
        )
    }
}

private func memberIdentityIndex(for tracks: [Track]) -> [MusicDatabaseTrackID: MemberIdentity] {
    var identities: [MusicDatabaseTrackID: MemberIdentity] = [:]
    for identity in memberIdentities(for: tracks) where identities[identity.databaseID] == nil {
        identities[identity.databaseID] = identity
    }
    return identities
}

func scopeCertificate(
    revision: MirrorRevision,
    inventoryChange: InventoryChange,
    testArtists: [String] = [],
    trackIDs: [MusicDatabaseTrackID],
    observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> ScopeCertificate {
    guard case let .replace(membership, _, _, _) = inventoryChange else {
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

func inventoryIDs(_ change: InventoryChange) -> [MusicDatabaseTrackID]? {
    guard case let .replace(_, ids, _, _) = change else { return nil }
    return ids
}

func applyInventory(_ change: InventoryChange, to tracks: inout [Track]) {
    guard let ids = inventoryIDs(change) else { return }
    let presentIDs = Set(ids.map(\.rawValue))
    tracks.removeAll { track in
        guard let databaseID = track.databaseID, track.id == databaseID.rawValue else { return false }
        return !presentIDs.contains(track.id)
    }
}
