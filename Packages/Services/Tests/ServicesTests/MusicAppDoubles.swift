import Foundation
@testable import Core
@testable import Services

actor MusicAppTestAccess: MusicAppIdentifying, MusicAppMutating, MusicAppVerifying {
    var writtenProperties: [MusicTrackUpdate] = []
    var batchUpdates: [[MusicTrackUpdate]] = []
    var tracksByID: [String: Track] = [:]
    var shouldThrow = false
    var shouldCancelWrite = false
    var shouldThrowBatch = false
    var shouldThrowFetch = false
    var shouldCancelFetch = false
    var shouldCancelBatch = false
    var shouldApplyBatchUpdates = true
    var shouldClearFetchedTracksAfterBatchUpdate = false
    var batchMutationLimit: Int?
    var singleWriteResult: MusicWriteResult = .changed
    var customWriteError: Error?
    var customBatchError: Error?
    private var writeErrorsByTrackID: [String: any Error] = [:]
    private var writeErrorsByProperty: [String: any Error] = [:]
    private var failingWriteTrackIDs: Set<String> = []
    private var writeAttemptHook: (@Sendable () throws -> Void)?
    private var fetchedMetadataIDs: [[MusicDatabaseTrackID]] = []
    private var fetchedIdentityScopes: [[String]] = []

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        fetchedMetadataIDs.append(databaseIDs)
        if shouldThrowFetch {
            throw MockScriptError.intentional
        }
        if shouldCancelFetch {
            throw CancellationError()
        }
        return databaseIDs.compactMap { tracksByID[$0.rawValue] }
    }

    func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Track] {
        fetchedIdentityScopes.append(artists)
        if shouldThrowFetch {
            throw MockScriptError.intentional
        }
        if shouldCancelFetch {
            throw CancellationError()
        }
        return Array(tracksByID.values)
    }

    func update(
        _ update: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        try await performWrite(
            update,
            onAttempt: onAttempt
        )
    }

    private func performWrite(
        _ update: MusicTrackUpdate,
        onAttempt: WriteAttemptHook
    ) async throws -> MusicWriteResult {
        let databaseID = update.databaseID.rawValue
        if shouldCancelWrite {
            throw CancellationError()
        }
        if let customWriteError {
            try writeAttemptHook?()
            try await onAttempt()
            throw customWriteError
        }
        if let writeError = writeErrorsByTrackID[databaseID] {
            try writeAttemptHook?()
            try await onAttempt()
            throw writeError
        }
        if let writeError = writeErrorsByProperty[update.property.rawValue] {
            try writeAttemptHook?()
            try await onAttempt()
            throw writeError
        }
        if shouldThrow || failingWriteTrackIDs.contains(databaseID) {
            throw MockScriptError.intentional
        }
        writtenProperties.append(update)
        if currentValue(for: update.property, inTrackWithID: databaseID) == update.value {
            // The real bridge fires the attempt hook for every dispatched
            // response, including "no change".
            try writeAttemptHook?()
            try await onAttempt()
            return .noChange
        }
        if singleWriteResult == .changed {
            apply(property: update.property, value: update.value, toTrackWithID: databaseID)
        }
        try writeAttemptHook?()
        try await onAttempt()
        return singleWriteResult
    }

    func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        try await performBatch(updates, onAttempt: onAttempt)
    }

    private func performBatch(
        _ updates: [MusicTrackUpdate],
        onAttempt: WriteAttemptHook
    ) async throws {
        batchUpdates.append(updates)
        if shouldCancelBatch {
            throw CancellationError()
        }
        if let customBatchError {
            try await onAttempt()
            throw customBatchError
        }
        if shouldThrowBatch {
            throw MockScriptError.intentional
        }
        if shouldApplyBatchUpdates {
            for update in updates.prefix(batchMutationLimit ?? updates.count) {
                apply(
                    property: update.property,
                    value: update.value,
                    toTrackWithID: update.databaseID.rawValue
                )
            }
        }
        if shouldClearFetchedTracksAfterBatchUpdate {
            tracksByID.removeAll()
        }
        try await onAttempt()
        try verifyBatchUpdates(updates)
    }

    func setFetchThrowMode(_ shouldFail: Bool) {
        shouldThrowFetch = shouldFail
    }

    func setFetchCancellationMode(_ isEnabled: Bool) {
        shouldCancelFetch = isEnabled
    }

    func setThrowMode(_ shouldFail: Bool) {
        shouldThrow = shouldFail
    }

    func setWriteCancellationMode(_ shouldCancel: Bool) {
        shouldCancelWrite = shouldCancel
    }

    func setWriteAttemptHook(_ hook: (@Sendable () throws -> Void)?) {
        writeAttemptHook = hook
    }

    func setBatchThrowMode(_ shouldFail: Bool) {
        shouldThrowBatch = shouldFail
    }

    func setBatchCancellationMode(_ shouldCancel: Bool) {
        shouldCancelBatch = shouldCancel
    }

    func setBatchMutationEnabled(_ isEnabled: Bool) {
        shouldApplyBatchUpdates = isEnabled
    }

    func setFetchedTracksClearedAfterBatchUpdate(_ isEnabled: Bool) {
        shouldClearFetchedTracksAfterBatchUpdate = isEnabled
    }

    func setBatchMutationLimit(_ limit: Int?) {
        batchMutationLimit = limit
    }

    func setSingleWriteResult(_ result: MusicWriteResult) {
        singleWriteResult = result
    }

    func setCustomWriteError(_ error: Error?) {
        customWriteError = error
    }

    func setWriteError(_ error: (any Error)?, for trackID: String) {
        writeErrorsByTrackID[trackID] = error
    }

    func setWriteError(_ error: (any Error)?, forProperty property: String) {
        writeErrorsByProperty[property] = error
    }

    func setCustomBatchError(_ error: Error?) {
        customBatchError = error
    }

    func setFailingWriteTrackIDs(_ trackIDs: Set<String>) {
        failingWriteTrackIDs = trackIDs
    }

    func setFetchedTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.databaseID?.rawValue ?? track.id, track)
        })
    }

    func fetchMetadataCalls() -> [[MusicDatabaseTrackID]] {
        fetchedMetadataIDs
    }

    func identityScopes() -> [[String]] {
        fetchedIdentityScopes
    }

    private func apply(property: MusicTrackProperty, value: String, toTrackWithID trackID: String) {
        guard var track = tracksByID[trackID] else { return }

        switch property {
        case .genre:
            track.genre = value
        case .year:
            track.year = Int(value)
        case .name:
            track.name = value
        case .album:
            track.album = value
        case .artist:
            track.artist = value
        case .albumArtist:
            track.albumArtist = value
        }
        tracksByID[trackID] = track
    }

    private func currentValue(for property: MusicTrackProperty, inTrackWithID trackID: String) -> String? {
        guard let track = tracksByID[trackID] else { return nil }
        return property.currentValue(in: track)
    }

    private func verifyBatchUpdates(_ updates: [MusicTrackUpdate]) throws {
        let failedCount = updates.count(where: { update in
            guard let track = tracksByID[update.databaseID.rawValue],
                  let currentValue = update.property.currentValue(in: track)
            else {
                return true
            }
            return currentValue != update.value
        })

        guard failedCount == 0 else {
            throw MusicBatchVerificationError(
                updateCount: updates.count,
                failedCount: failedCount,
                reason: "test batch verification failure"
            )
        }
    }
}

enum MockScriptError: Error {
    case intentional
}
