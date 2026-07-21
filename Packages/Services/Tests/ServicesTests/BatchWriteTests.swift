import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - batch write verification")
struct BatchWriteTests {
    @Test("Unavailable batch verification reports an unknown outcome")
    func unknownBatchVerification() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setFetchedTracksClearedAfterBatchUpdate(true)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    @Test("Direct batch timeout invalidates attempted write caches")
    func directBatchTimeoutClearsCaches() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setCustomBatchError(
            AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
        )
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: 1999,
            source: "discogs",
            timestamp: .now,
            ttl: nil
        ))
        await fixture.bridge.setFetchedTracks([track])

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                acceptedProposals(for: track),
                progressHandler: ignoreProgress
            )
        }

        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "discogs"
        ) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    @Test("Generated mapped partial batches report an unknown outcome")
    func mappedPartialBatchIsUnknown() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Song (Remastered 2020)",
            genre: nil,
            year: 1999
        )
        let appleScriptTrack = makeTrack(
            id: "AS1",
            name: "Song (Remastered 2020)",
            genre: nil,
            year: 1999
        )
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )
        let fixture = await makeCoordinator(batchUpdatesEnabled: true, idMapper: mapper)
        await fixture.bridge.setBatchMutationLimit(1)
        await fixture.bridge.setFetchedTracks([appleScriptTrack])

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.updateTracks(
                [musicKitTrack],
                options: UpdateOptions(
                    updateGenre: false,
                    updateYear: true,
                    cleanTrackNames: true
                ),
                progressHandler: ignoreProgress
            )
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.trackID) == ["AS1", "AS1"])
        #expect(written.isEmpty)
    }

    @Test("A pre-dispatch batch cancellation emits only the before-attempt checkpoint")
    func propagatesBatchCancellation() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchCancellationMode(true)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)
        let checkpoints = CheckpointRecorder()

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress,
                checkpoint: { await checkpoints.append($0.boundary) }
            )
        }

        #expect(await checkpoints.boundaries == [.beforeAttempt])
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("A stale reviewed item does not discard a valid batch peer")
    func isolatesStalePeer() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let reviewedTrack = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        let currentTrack = makeTrack(id: "MK1", genre: "Jazz", year: 1999)
        await fixture.bridge.setFetchedTracks([currentTrack])
        let proposals = acceptedProposals(for: reviewedTrack)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.map { $0.map(\.property) } == [["year"]])
        #expect(written.isEmpty)
        #expect(result.entries.map(\.changeType) == [.yearUpdate])
        #expect(result.noOpEntries.isEmpty)
        #expect(result.failedTrackIDs == ["MK1"])
        #expect(result.errorDescriptions.count == 1)
        #expect(result.errorDescriptions.first?.contains("reviewed value no longer matches Music.app") == true)
        #expect(result.hasPartialFailures)
    }

    @Test("Pre-run batch failure falls back to single writes")
    func preRunBatchFailureFallsBackToSingleWrites() async throws {
        try await assertPreRunBatchFailureFallsBack(
            existingGenre: "Rock",
            expectedEntries: [.genreUpdate, .yearUpdate],
            expectedNoOpEntries: []
        )
    }

    @Test("Pre-run batch failure falls back when one value already matches")
    func preRunBatchFailureFallsBackWhenOneValueAlreadyMatches() async throws {
        try await assertPreRunBatchFailureFallsBack(
            existingGenre: "Stoner Rock",
            expectedEntries: [.yearUpdate],
            expectedNoOpEntries: [.genreUpdate]
        )
    }

    private func assertPreRunBatchFailureFallsBack(
        existingGenre: String,
        expectedEntries: [ChangeType],
        expectedNoOpEntries: [ChangeType]
    ) async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchThrowMode(true)
        let track = makeTrack(id: "MK1", genre: existingGenre, year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.map(\.property) == ["genre", "year"])
        #expect(result.entries.map(\.changeType) == expectedEntries)
        #expect(result.noOpEntries.map(\.changeType) == expectedNoOpEntries)
        #expect(!result.hasPartialFailures)
    }

    @Test("Partial batch verification reports an unknown outcome")
    func partialVerificationIsUnknown() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchMutationLimit(1)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    private func makeCoordinator(
        batchUpdatesEnabled: Bool,
        idMapper: (any TrackIDMapping)? = nil
    ) async -> BatchWriteFixture {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let snapshot = MockLibrarySnapshotService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchWriteTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
        let apiService = MockAPIService(yearResult: YearResult(
            year: 2001,
            confidence: 95,
            yearScores: [2001: 95]
        ))
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                scriptBridge: bridge,
                stores: .init(trackStore: MockTrackStore(), cache: cache),
                undoCoordinator: undo,
                idMapper: idMapper,
                librarySnapshotService: snapshot
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: batchUpdatesEnabled,
                maxBatchUpdateSize: 5
            )
        )
        return BatchWriteFixture(coordinator: coordinator, bridge: bridge, cache: cache, snapshot: snapshot)
    }

    private func acceptedProposals(for track: Track) -> [ProposedChange] {
        [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: true
            ),
        ]
    }

    private func makeTrack(
        id: String,
        name: String = "Come Together",
        genre: String?,
        year: Int?
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: "Beatles",
            album: "Abbey Road",
            genre: genre,
            year: year,
            trackStatus: nil
        )
    }
}

private func ignoreProgress(_ update: ProgressUpdate) {
    _ = update
}

private struct BatchWriteFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let cache: MockCacheService
    let snapshot: MockLibrarySnapshotService
}

private actor CheckpointRecorder {
    private(set) var boundaries: [CheckpointBoundary] = []

    func append(_ boundary: CheckpointBoundary) {
        boundaries.append(boundary)
    }
}
