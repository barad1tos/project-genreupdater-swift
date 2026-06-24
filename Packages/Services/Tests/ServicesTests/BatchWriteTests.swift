import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - batch write verification")
struct BatchWriteTests {
    @Test("Unavailable batch verification does not fall back to single reviewed writes")
    func unavailableBatchVerificationDoesNotFallBackToSingleReviewedWrites() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setFetchedTracksClearedAfterBatchUpdate(true)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedGenreAndYearProposals(for: track)

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
            Issue.record("Expected all writes to fail when batch verification is unavailable")
        } catch let error as UpdateCoordinatorError {
            guard case let .allTracksFailed(count, errorDescriptions) = error else {
                Issue.record("Expected allTracksFailed, got \(error)")
                return
            }
            #expect(count == 2)
            #expect(errorDescriptions.allSatisfy { $0.contains("could not be verified") })
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
    }

    @Test("Generated mapped partial batch failures keep domain track IDs")
    func generatedMappedPartialBatchFailuresKeepDomainTrackIDs() async throws {
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

        let result = try await fixture.coordinator.updateTracks(
            [musicKitTrack],
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                cleanTrackNames: true
            ),
            progressHandler: ignoreProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.trackID) == ["AS1", "AS1"])
        #expect(written.isEmpty)
        #expect(result.entries.map(\.trackID) == ["MK1"])
        #expect(result.entries.map(\.changeType) == [.trackCleaning])
        #expect(result.failedTrackIDs == ["MK1"])
        #expect(result.errorDescriptions.first?.contains("MK1") == true)
        #expect(result.errorDescriptions.first?.contains("AS1") == false)
        #expect(result.hasPartialFailures)
    }

    private func makeCoordinator(
        batchUpdatesEnabled: Bool,
        idMapper: (any TrackIDMapping)? = nil
    ) async -> BatchWriteFixture {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchWriteTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
        let apiService = MockAPIService(yearResult: YearResult(
            year: 2001,
            confidence: 95,
            yearScores: [2001: 95]
        ))
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: undo,
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: batchUpdatesEnabled,
                maxBatchUpdateSize: 5
            )
        )
        return BatchWriteFixture(coordinator: coordinator, bridge: bridge, cache: cache)
    }

    private func acceptedGenreAndYearProposals(for track: Track) -> [ProposedChange] {
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
}
