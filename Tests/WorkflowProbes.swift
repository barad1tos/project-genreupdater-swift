import Core
import Foundation
import Services

actor WorkflowPendingVerificationService: PendingVerificationService {
    private var entries: [PendingAlbumEntry]
    private let seededDueEntries: [PendingAlbumEntry]?
    private let seededProblematicAlbums: [ProblematicPendingAlbum]
    private let pendingSnapshotDelay: PendingSnapshotDelay?
    private let timestampUpdateFailure: (any Error)?
    private var removals: [(artist: String, album: String)] = []
    private var timestampUpdates = 0

    init(
        entries: [PendingAlbumEntry],
        dueEntries: [PendingAlbumEntry]? = nil,
        problematicAlbums: [ProblematicPendingAlbum] = [],
        pendingSnapshotDelay: PendingSnapshotDelay? = nil,
        timestampUpdateFailure: (any Error)? = nil
    ) {
        self.entries = entries
        self.seededDueEntries = dueEntries
        self.seededProblematicAlbums = problematicAlbums
        self.pendingSnapshotDelay = pendingSnapshotDelay
        self.timestampUpdateFailure = timestampUpdateFailure
    }

    func initialize() async throws {
        // Test double has no external resources to initialize.
    }

    func markForVerification(
        artist _: String,
        album _: String,
        reason _: String,
        metadata _: [String: String]?,
        recheckDays _: Int?
    ) async {
        // These tests seed pending entries directly.
    }

    func removeFromPending(artist: String, album: String) async {
        removals.append((artist: artist, album: album))
        let key = AlbumIdentity.key(artist: artist, album: album)
        entries.removeAll { AlbumIdentity.key(artist: $0.artist, album: $0.album) == key }
    }

    func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        entries.first { $0.artist == artist && $0.album == album }
    }

    func getAttemptCount(artist: String, album: String) async -> Int {
        await getEntry(artist: artist, album: album)?.attemptCount ?? 0
    }

    func isVerificationNeeded(artist: String, album: String) async -> Bool {
        await getEntry(artist: artist, album: album) != nil
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        entries
    }

    func getPendingVerificationSnapshot() async -> (all: [PendingAlbumEntry], due: [PendingAlbumEntry]) {
        let snapshot = (entries, currentDueEntries())
        await pendingSnapshotDelay?.waitAfterCapturingFirstSnapshot()
        return snapshot
    }

    func getProblematicPendingAlbums(minAttempts: Int) async -> [ProblematicPendingAlbum] {
        await pendingSnapshotDelay?.recordProblematicCountRequest()
        let currentEntryKeys = currentEntryKeys()
        return seededProblematicAlbums.filter { problematicAlbum in
            problematicAlbum.totalAttempts >= minAttempts
                && currentEntryKeys.contains(entryKey(problematicAlbum.entry))
        }
    }

    func shouldAutoVerify() async -> Bool {
        true
    }

    func updateVerificationTimestamp() async throws {
        if let timestampUpdateFailure {
            throw timestampUpdateFailure
        }
        timestampUpdates += 1
    }

    func removedAlbums() -> [(artist: String, album: String)] {
        removals
    }

    func verificationTimestampUpdateCount() -> Int {
        timestampUpdates
    }

    private func currentDueEntries() -> [PendingAlbumEntry] {
        guard let seededDueEntries else { return entries }

        let currentEntryKeys = currentEntryKeys()
        var dueEntries: [PendingAlbumEntry] = []
        for entry in seededDueEntries {
            let key = entryKey(entry)
            guard currentEntryKeys.contains(key) else { continue }
            dueEntries.append(entry)
        }
        return dueEntries
    }

    private func currentEntryKeys() -> Set<String> {
        Set(entries.map { entryKey($0) })
    }

    private func entryKey(_ entry: PendingAlbumEntry) -> String {
        AlbumIdentity.key(artist: entry.artist, album: entry.album)
    }
}

actor PendingSnapshotDelay {
    private enum Timeout: Error, CustomStringConvertible {
        case firstSnapshot
        case delayedRefreshCompletion

        var description: String {
            switch self {
            case .firstSnapshot:
                "pending scope refresh did not capture its first snapshot before timeout"
            case .delayedRefreshCompletion:
                "delayed pending scope refresh did not complete before timeout"
            }
        }
    }

    private static let maximumWaitIterations = 200
    private var shouldDelayFirstSnapshot = true
    private var hasCapturedFirstSnapshot = false
    private var isFirstSnapshotReleased = false
    private var hasReturnedDelayedSnapshot = false
    private var hasCompletedDelayedPendingScopeRefresh = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitAfterCapturingFirstSnapshot() async {
        guard shouldDelayFirstSnapshot else { return }

        shouldDelayFirstSnapshot = false
        hasCapturedFirstSnapshot = true

        if !isFirstSnapshotReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        hasReturnedDelayedSnapshot = true
    }

    func waitForCapturedFirstSnapshot() async throws {
        for _ in 0 ..< Self.maximumWaitIterations {
            if hasCapturedFirstSnapshot {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw Timeout.firstSnapshot
    }

    func releaseFirstSnapshot() {
        isFirstSnapshotReleased = true
        resumeAll(&releaseContinuations)
    }

    private func resumeAll(_ continuations: inout [CheckedContinuation<Void, Never>]) {
        let continuationsToResume = continuations
        continuations.removeAll()
        for continuation in continuationsToResume {
            continuation.resume()
        }
    }

    func recordProblematicCountRequest() {
        // Hook retained for delayed snapshot tests that need the service call to stay observable.
    }

    func recordDelayedPendingScopeRefreshCompletion() {
        guard hasReturnedDelayedSnapshot else { return }

        hasCompletedDelayedPendingScopeRefresh = true
    }

    func waitForDelayedPendingScopeRefreshCompletion() async throws {
        for _ in 0 ..< Self.maximumWaitIterations {
            if hasCompletedDelayedPendingScopeRefresh {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw Timeout.delayedRefreshCompletion
    }
}

actor WorkflowTrackIDMapper: TrackIDMapping {
    private var enrichedTracks: [String: Track]
    private var appleScriptIDsByMusicKitID: [String: String]

    init(
        enrichedTracks: [Track],
        appleScriptIDsByMusicKitID: [String: String]
    ) {
        self.enrichedTracks = Dictionary(uniqueKeysWithValues: enrichedTracks.map { ($0.id, $0) })
        self.appleScriptIDsByMusicKitID = appleScriptIDsByMusicKitID
    }

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        appleScriptIDsByMusicKitID[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        enrichedTracks[musicKitTrack.id]
    }

    func seed(
        enrichedTracks newEnrichedTracks: [Track],
        appleScriptIDsByMusicKitID newAppleScriptIDs: [String: String]
    ) {
        for track in newEnrichedTracks {
            enrichedTracks[track.id] = track
        }
        appleScriptIDsByMusicKitID.merge(newAppleScriptIDs) { _, newValue in newValue }
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        enrichedTracks[musicKitID] != nil && appleScriptIDsByMusicKitID[musicKitID] != nil
    }
}
