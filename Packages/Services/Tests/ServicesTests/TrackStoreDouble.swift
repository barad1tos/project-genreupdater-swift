import Foundation
@testable import Core
@testable import Services

struct AppliedTrackUpdate {
    let id: String
    let genreUpdated: Bool?
    let yearUpdated: Bool?
}

actor MockTrackStore: TrackStateStore {
    var tracks: [Track] = []
    private var certificates: [ScopeCertificate] = []
    private var revision: MirrorRevision
    private(set) var appliedUpdates: [AppliedTrackUpdate] = []
    private(set) var observedUpdateIDs: [String] = []
    private var shouldCancelReads = false
    private var shouldFailMirror = false
    private var appliedUpdateHook: (@Sendable () throws -> Void)?

    init(revision: MirrorRevision = .initial) {
        self.revision = revision
    }

    func failAppliedUpdates() {
        shouldFailMirror = true
    }

    func resumeAppliedUpdates() {
        shouldFailMirror = false
    }

    func setReadCancellation(_ isEnabled: Bool) {
        shouldCancelReads = isEnabled
    }

    func setAppliedUpdateHook(_ hook: (@Sendable () throws -> Void)?) {
        appliedUpdateHook = hook
    }

    func initialize() async throws {}

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try mirrorSnapshot(revision: revision, tracks: tracks, certificates: certificates)
    }

    @discardableResult
    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        guard commit.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: commit.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()
        switch commit.certificates {
        case .preserve:
            break
        case .invalidate:
            certificates = []
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        }
        if case let .replace(_, ids, _, _) = commit.inventoryChange {
            let presentIDs = Set(ids.map(\.rawValue))
            tracks.removeAll { !presentIDs.contains($0.id) }
        }
        for track in commit.upserts {
            if let trackIndex = tracks.firstIndex(where: { $0.id == track.id }) {
                tracks[trackIndex] = track
            } else {
                tracks.append(track)
            }
        }
        revision = nextRevision
        return try MirrorCommitResult(
            revision: revision,
            snapshot: mirrorSnapshot(revision: revision, tracks: tracks, certificates: certificates)
        )
    }

    func getTrack(byID id: String) async throws -> Track? {
        if shouldCancelReads {
            throw CancellationError()
        }
        return tracks.first { $0.id == id }
    }

    func commitAppliedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        if shouldFailMirror {
            throw MockScriptError.intentional
        }
        if let trackIndex = tracks.firstIndex(where: { $0.id == change.trackID }) {
            tracks[trackIndex] = try tracks[trackIndex].applying(change)
        }
        appliedUpdates.append(AppliedTrackUpdate(
            id: change.trackID,
            genreUpdated: change.changeType == .genreUpdate ? true : nil,
            yearUpdated: change.changeType == .yearUpdate || change.changeType == .yearRevert ? true : nil
        ))
        try appliedUpdateHook?()
        revision = try revision.advanced()
        return revision
    }

    func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        observedUpdateIDs.append(change.trackID)
        return try await commitAppliedChange(change)
    }

    func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID _: UUID
    ) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }

    func getUnprocessedTracks() async throws -> [Track] {
        tracks
    }

    func trackCount() async throws -> Int {
        tracks.count
    }
}
