import Foundation
@testable import Core
@testable import Services

struct ScriptFetchRequest {
    let trackIDs: [String]
    let batchSize: Int
    let timeout: Duration?
}

actor MockAppleScriptClient: AppleScriptClient {
    var writtenProperties: [TrackPropertyUpdate] = []
    var batchUpdates: [[TrackPropertyUpdate]] = []
    var trackIDsToFetch: [String] = []
    var tracksByID: [String: Track] = [:]
    var shouldThrow = false
    var shouldCancelWrite = false
    var shouldThrowBatch = false
    var shouldThrowFetch = false
    var shouldCancelBatch = false
    var shouldApplyBatchUpdates = true
    var shouldClearFetchedTracksAfterBatchUpdate = false
    var batchMutationLimit: Int?
    var singleWriteResult: AppleScriptWriteResult = .changed
    var customWriteError: Error?
    var customBatchError: Error?
    private var writeErrorsByTrackID: [String: any Error] = [:]
    private var writeErrorsByProperty: [String: any Error] = [:]
    private var failingWriteTrackIDs: Set<String> = []
    private var writeAttemptHook: (@Sendable () throws -> Void)?
    private var fetchedTracksByIDsCalls: [ScriptFetchRequest] = []
    private var fetchedAllTrackIDsTimeouts: [Duration?] = []

    func initialize() async throws {
        // Mock: no initialization behavior required.
    }

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchedTracksByIDsCalls.append(ScriptFetchRequest(
            trackIDs: trackIDs,
            batchSize: batchSize,
            timeout: timeout
        ))
        if shouldThrowFetch {
            throw MockScriptError.intentional
        }
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout: Duration?) async throws -> [String] {
        fetchedAllTrackIDsTimeouts.append(timeout)
        return trackIDsToFetch
    }

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String
    ) async throws -> AppleScriptWriteResult {
        try await performWrite(
            trackID: trackID,
            property: property,
            value: value,
            onAttempt: nil
        )
    }

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> AppleScriptWriteResult {
        try await performWrite(
            trackID: trackID,
            property: property,
            value: value,
            onAttempt: onAttempt
        )
    }

    private func performWrite(
        trackID: String,
        property: String,
        value: String,
        onAttempt: WriteAttemptHook?
    ) async throws -> AppleScriptWriteResult {
        if shouldCancelWrite {
            throw CancellationError()
        }
        if let customWriteError {
            try writeAttemptHook?()
            try await onAttempt?()
            throw customWriteError
        }
        if let writeError = writeErrorsByTrackID[trackID] {
            try writeAttemptHook?()
            try await onAttempt?()
            throw writeError
        }
        if let writeError = writeErrorsByProperty[property] {
            try writeAttemptHook?()
            try await onAttempt?()
            throw writeError
        }
        if shouldThrow || failingWriteTrackIDs.contains(trackID) {
            throw MockScriptError.intentional
        }
        writtenProperties.append(TrackPropertyUpdate(trackID: trackID, property: property, value: value))
        if currentValue(for: property, inTrackWithID: trackID) == value {
            // The real bridge fires the attempt hook for every dispatched
            // response, including "no change".
            try writeAttemptHook?()
            try await onAttempt?()
            return .noChange
        }
        if singleWriteResult == .changed {
            apply(property: property, value: value, toTrackWithID: trackID)
        }
        try writeAttemptHook?()
        try await onAttempt?()
        return singleWriteResult
    }

    func batchUpdateTracks(_ updates: [TrackPropertyUpdate]) async throws {
        try await performBatch(updates, onAttempt: nil)
    }

    func batchUpdateTracks(
        _ updates: [TrackPropertyUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        try await performBatch(updates, onAttempt: onAttempt)
    }

    private func performBatch(
        _ updates: [TrackPropertyUpdate],
        onAttempt: WriteAttemptHook?
    ) async throws {
        batchUpdates.append(updates)
        if shouldCancelBatch {
            throw CancellationError()
        }
        if let customBatchError {
            try await onAttempt?()
            throw customBatchError
        }
        if shouldThrowBatch {
            throw MockScriptError.intentional
        }
        if shouldApplyBatchUpdates {
            for update in updates.prefix(batchMutationLimit ?? updates.count) {
                apply(property: update.property, value: update.value, toTrackWithID: update.trackID)
            }
        }
        if shouldClearFetchedTracksAfterBatchUpdate {
            tracksByID.removeAll()
        }
        try await onAttempt?()
        try verifyBatchUpdates(updates)
    }

    func setFetchThrowMode(_ shouldFail: Bool) {
        shouldThrowFetch = shouldFail
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

    func setSingleWriteResult(_ result: AppleScriptWriteResult) {
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
        trackIDsToFetch = tracks.map(\.id)
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func fetchTracksByIDsCalls() -> [ScriptFetchRequest] {
        fetchedTracksByIDsCalls
    }

    func fetchAllTrackIDsTimeouts() -> [Duration?] {
        fetchedAllTrackIDsTimeouts
    }

    private func apply(property: String, value: String, toTrackWithID trackID: String) {
        guard var track = tracksByID[trackID] else { return }

        switch property {
        case "genre":
            track.genre = value
        case "year":
            track.year = Int(value)
        case "name":
            track.name = value
        case "album":
            track.album = value
        case "artist":
            track.artist = value
        case "album_artist":
            track.albumArtist = value
        default:
            return
        }
        tracksByID[trackID] = track
    }

    private func currentValue(for property: String, inTrackWithID trackID: String) -> String? {
        guard let track = tracksByID[trackID],
              let property = AppleScriptTrackProperty(rawValue: property)
        else {
            return nil
        }
        return property.currentValue(in: track)
    }

    private func verifyBatchUpdates(_ updates: [TrackPropertyUpdate]) throws {
        let failedCount = updates.count(where: { update in
            guard let track = tracksByID[update.trackID],
                  let property = AppleScriptTrackProperty(rawValue: update.property),
                  let currentValue = property.currentValue(in: track)
            else {
                return true
            }
            return currentValue != update.value
        })

        guard failedCount == 0 else {
            throw AppleScriptBatchVerificationError(
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
