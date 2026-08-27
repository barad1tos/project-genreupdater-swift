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
        try await applyMirror(TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .replace(.fullLibrary),
            membershipChange: replacementMembership(for: canonicalTracks),
            repairs: [],
            upserts: canonicalTracks
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
    coverage: MirrorCoverage
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
        coverage: coverage
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
