import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - UpdateCoordinatorError Tests

@Suite("UpdateCoordinatorError — error descriptions and construction")
struct UpdateCoordinatorErrorTests {
    @Test("trackNotEditable includes track ID in description")
    func trackNotEditable() {
        let error = UpdateCoordinatorError.trackNotEditable(trackID: "ABC123")
        let description = error.errorDescription ?? ""
        #expect(description.contains("ABC123"))
    }

    @Test("trackNotProcessable includes track ID and status in description")
    func trackNotProcessable() {
        let error = UpdateCoordinatorError.trackNotProcessable(
            trackID: "ABC123",
            status: "no longer available"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("ABC123"))
        #expect(description.contains("no longer available"))
    }

    @Test("noChangesProduced has a description")
    func noChangesProduced() {
        let error = UpdateCoordinatorError.noChangesProduced
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("allTracksFailed includes count in description")
    func allTracksFailed() {
        let error = UpdateCoordinatorError.allTracksFailed(
            count: 5,
            errorDescriptions: ["error1", "error2"]
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("5"))
        #expect(description.contains("error1"))
        #expect(description.contains("error2"))
    }

    @Test("Single-track allTracksFailed exposes underlying write failure")
    func singleTrackAllFailedKeepsWriteFailureReason() {
        let error = UpdateCoordinatorError.allTracksFailed(
            count: 1,
            errorDescriptions: ["Failed to write year for track T1: Year value is out of range"]
        )

        #expect(error.errorDescription == "Failed to write year for track T1: Year value is out of range")
    }

    @Test("Single-track multi-operation allTracksFailed keeps every write failure visible")
    func singleTrackMultiOperationAllFailedKeepsWriteFailuresVisible() {
        let error = UpdateCoordinatorError.allTracksFailed(
            count: 1,
            errorDescriptions: [
                "Failed to write genre for track T1: Genre write failed",
                "Failed to write year for track T1: Year write failed",
            ]
        )
        let description = error.errorDescription ?? ""

        #expect(description.contains("2 update operations"))
        #expect(description.contains("Failed to write genre for track T1"))
        #expect(description.contains("Failed to write year for track T1"))
    }

    @Test("writeFailed includes track ID, property, and reason in description")
    func writeFailed() {
        let error = UpdateCoordinatorError.writeFailed(
            trackID: "T1",
            property: "genre",
            reason: "Permission denied"
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("T1"))
        #expect(description.contains("genre"))
        #expect(description.contains("Permission denied"))
    }

    @Test("missingAppleScriptID includes track ID in description")
    func missingAppleScriptID() {
        let error = UpdateCoordinatorError.missingAppleScriptID(trackID: "MK1")
        let description = error.errorDescription ?? ""
        #expect(description.contains("MK1"))
    }
}

// MARK: - BatchUpdateResult Tests

@Suite("BatchUpdateResult — computed properties")
struct BatchUpdateResultTests {
    @Test("hasPartialFailures is true when both entries and failures exist")
    func partialFailures() {
        let entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Artist"
        )
        let result = BatchUpdateResult(
            entries: [entry],
            failedTrackIDs: ["T2"],
            errorDescriptions: ["Failed"]
        )
        #expect(result.hasPartialFailures == true)
    }

    @Test("hasPartialFailures is false when no failures")
    func noFailures() {
        let entry = ChangeLogEntry(
            changeType: .genreUpdate,
            trackID: "T1",
            artist: "Artist"
        )
        let result = BatchUpdateResult(
            entries: [entry],
            failedTrackIDs: [],
            errorDescriptions: []
        )
        #expect(result.hasPartialFailures == false)
    }

    @Test("hasPartialFailures is false when all failed (no entries)")
    func allFailed() {
        let result = BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["T1"],
            errorDescriptions: ["Failed"]
        )
        #expect(result.hasPartialFailures == false)
    }

    @Test("failed counts separate operations from tracks")
    func failedCountsSeparateOperationsFromTracks() {
        let result = BatchUpdateResult(
            entries: [],
            failedTrackIDs: ["T1", "T1", "T2"],
            errorDescriptions: ["Genre failed", "Year failed", "Genre failed"]
        )
        #expect(result.failedOperationCount == 3)
        #expect(result.failedTrackCount == 2)
    }

    @Test("applied counts separate operations from tracks")
    func appliedCountsSeparateOperationsFromTracks() {
        let result = BatchUpdateResult(
            entries: [
                ChangeLogEntry(changeType: .genreUpdate, trackID: "T1", artist: "Artist"),
                ChangeLogEntry(changeType: .yearUpdate, trackID: "T1", artist: "Artist"),
                ChangeLogEntry(changeType: .genreUpdate, trackID: "T2", artist: "Artist"),
            ],
            failedTrackIDs: [],
            errorDescriptions: []
        )
        #expect(result.appliedOperationCount == 3)
        #expect(result.updatedTrackCount == 2)
    }
}

// MARK: - UpdateOptions Tests

@Suite("UpdateOptions — defaults and custom values")
struct UpdateOptionsTests {
    @Test("Default options have expected values")
    func defaults() {
        let options = UpdateOptions()
        #expect(options.updateGenre == true)
        #expect(options.updateYear == true)
        #expect(options.forceYearLookup == false)
        #expect(options.cleanTrackNames == false)
        #expect(options.cleanAlbumNames == false)
        #expect(options.minConfidence == 60)
        #expect(options.autoAccept == false)
    }

    @Test("Custom options are preserved")
    func customValues() {
        let options = UpdateOptions(
            updateGenre: false,
            updateYear: true,
            forceYearLookup: true,
            cleanTrackNames: true,
            cleanAlbumNames: true,
            minConfidence: 90,
            autoAccept: true
        )
        #expect(options.updateGenre == false)
        #expect(options.forceYearLookup == true)
        #expect(options.cleanTrackNames == true)
        #expect(options.cleanAlbumNames == true)
        #expect(options.minConfidence == 90)
        #expect(options.autoAccept == true)
    }
}

// MARK: - UpdateCoordinator write failure Tests

@Suite("UpdateCoordinator — write failure handling")
struct UpdateCoordinatorWriteFailureTests {
    private func makeCoordinator(
        scriptBridge: MockAppleScriptClient
    ) async -> UpdateCoordinator {
        let store = MockTrackStore()
        let cache = MockCacheService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteFailureTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: scriptBridge, directory: undoDir)

        let yearResult = YearResult(
            year: 2020,
            confidence: 90,
            yearScores: [2020: 90]
        )
        let apiService = MockAPIService(yearResult: yearResult)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )

        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: scriptBridge,
                trackStore: store,
                cache: cache,
                undoCoordinator: undo
            ),
            genreDeterminator: GenreDeterminator()
        )
    }

    @Test("Write failure throws writeFailed error")
    func writeFailureThrows() async throws {
        let bridge = MockAppleScriptClient()
        await bridge.setThrowMode(true)
        let coordinator = await makeCoordinator(scriptBridge: bridge)

        let track = Track(
            id: "T1", name: "Song", artist: "Artist", album: "Album",
            year: 1969, trackStatus: nil
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await coordinator.updateTrack(
                track,
                options: UpdateOptions(updateGenre: false, updateYear: true),
                dryRun: false
            )
        }
    }

    @Test("Confidence filter removes low-confidence changes")
    func confidenceFilterRemovesLow() async throws {
        let bridge = MockAppleScriptClient()
        let store = MockTrackStore()
        let cache = MockCacheService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfFilterTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)

        // Only one source returns a low-confidence result; others return empty.
        // This prevents aggregation from boosting the combined score above threshold.
        let lowConfidence = MockAPIService(
            yearResult: YearResult(year: 2020, confidence: 30, yearScores: [2020: 30])
        )
        let emptyResult = MockAPIService(
            yearResult: YearResult()
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: lowConfidence,
            discogs: emptyResult,
            appleMusic: emptyResult
        )

        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: store,
                cache: cache,
                undoCoordinator: undo
            ),
            genreDeterminator: GenreDeterminator()
        )

        let track = Track(
            id: "T1", name: "Song", artist: "Artist", album: "Album",
            year: 1969, trackStatus: nil
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                minConfidence: 60
            ),
            dryRun: true
        )

        // The low-confidence change (30) should be filtered out by minConfidence (60)
        #expect(changes.isEmpty)
    }
}
