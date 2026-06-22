import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — accepted review application")
struct UpdateCoordinatorApplyAcceptedTests {
    @Test("Applying reviewed changes writes only accepted proposals")
    func applyingReviewedChangesWritesOnlyAcceptedProposals() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Electronic",
                confidence: 80,
                source: "Library",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1969",
                newValue: "1970",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: false
            ),
        ]

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].property == "genre")
        #expect(written[0].value == "Electronic")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].changeType == .genreUpdate)
    }

    @Test("Batch writes accepted same-track proposals when enabled")
    func batchWritesAcceptedSameTrackProposalsWhenEnabled() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedGenreAndYearProposals(for: track) + [
            ProposedChange(
                track: track,
                changeType: .trackCleaning,
                oldValue: "American Sleep - Single",
                newValue: "American Sleep",
                confidence: 88,
                source: "Cleaner",
                isAccepted: false
            ),
        ]

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches[0].map(\.property) == ["genre", "year"])
        #expect(batches[0].map(\.value) == ["Stoner Rock", "2001"])
        #expect(written.isEmpty)
        #expect(result.entries.map(\.changeType) == [.genreUpdate, .yearUpdate])
    }

    @Test("Batch writes accepted same-album year proposals when enabled")
    func batchWritesAcceptedSameAlbumYearProposalsWhenEnabled() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let firstTrack = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let secondTrack = makeEditableTrack(id: "MK2", genre: "Rock", year: 1998)
        await fixture.bridge.setFetchedTracks([firstTrack, secondTrack])
        let proposals = [
            ProposedChange(
                track: firstTrack,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: true
            ),
            ProposedChange(
                track: firstTrack,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library",
                isAccepted: false
            ),
            ProposedChange(
                track: secondTrack,
                changeType: .yearUpdate,
                oldValue: "1998",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: true
            ),
        ]

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.map(\.trackID) == ["MK1", "MK2"])
        #expect(batch.map(\.property) == ["year", "year"])
        #expect(batch.map(\.value) == ["2001", "2001"])
        #expect(written.isEmpty)
        #expect(result.entries.map(\.trackID) == ["MK1", "MK2"])
        #expect(result.entries.map(\.changeType) == [.yearUpdate, .yearUpdate])
    }

    @Test("Verified batch no-op writes do not record applied changes")
    func verifiedBatchNoOpWritesDoNotRecordAppliedChanges() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let track = makeEditableTrack(id: "MK1", genre: "Stoner Rock", year: 2001)
        await fixture.bridge.setFetchedTracks([track])
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 2001, confidence: 90)
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: 2001,
            source: "MusicBrainz",
            timestamp: Date(),
            ttl: 3600
        ))
        let proposals = acceptedGenreAndYearProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches[0].map(\.property) == ["genre", "year"])
        #expect(written.isEmpty)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "MusicBrainz"
        ) == nil)
    }

    @Test("Verified batch no-op uses refreshed AppleScript metadata")
    func verifiedBatchNoOpUsesRefreshedAppleScriptMetadata() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let staleTrack = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let freshTrack = makeEditableTrack(id: "MK1", genre: "Stoner Rock", year: 2001)
        await fixture.bridge.setFetchedTracks([freshTrack])
        let proposals = acceptedGenreAndYearProposals(for: staleTrack)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches[0].map(\.property) == ["genre", "year"])
        #expect(written.isEmpty)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Unverified batch success falls back to single reviewed writes")
    func unverifiedBatchSuccessFallsBackToSingleReviewedWrites() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        await fixture.bridge.setBatchMutationEnabled(false)
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedGenreAndYearProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.map(\.property) == ["genre", "year"])
        #expect(written.map(\.value) == ["Stoner Rock", "2001"])
        #expect(result.entries.map(\.changeType) == [.genreUpdate, .yearUpdate])
    }

    @Test("Default reviewed writes keep single-write behavior")
    func defaultReviewedWritesKeepSingleWriteBehavior() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let proposals = acceptedGenreAndYearProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.isEmpty)
        #expect(written.map(\.property) == ["genre", "year"])
        #expect(result.entries.map(\.changeType) == [.genreUpdate, .yearUpdate])
    }

    @Test("Reviewed no-change write does not record an applied change")
    func reviewedNoChangeWriteDoesNotRecordAppliedChange() async throws {
        let fixture = await makeCoordinator()
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 90)
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: 2001,
            source: "MusicBrainz",
            timestamp: Date(),
            ttl: 3600
        ))
        let change = ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: ignoreAcceptedChangeProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(written.map(\.property) == ["year"])
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "MusicBrainz"
        ) == nil)
    }

    @Test("Batch failure falls back to single reviewed writes")
    func batchFailureFallsBackToSingleReviewedWrites() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        await fixture.bridge.setBatchThrowMode(true)
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedGenreAndYearProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.map(\.property) == ["genre", "year"])
        #expect(written.map(\.value) == ["Stoner Rock", "2001"])
        #expect(result.entries.map(\.changeType) == [.genreUpdate, .yearUpdate])
    }

    @Test("Test artist allow-list skips out-of-scope reviewed changes")
    func artistAllowListSkipsOutOfScopeReviewedChanges() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["In Flames"])
        )
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Electronic",
                confidence: 80,
                source: "Library",
                isAccepted: true
            ),
        ]

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Mapped writes fail before calling AppleScript when AppleScript ID is missing")
    func mappedWriteFailsBeforeCallingAppleScriptWhenAppleScriptIDIsMissing() async throws {
        let mapper = TrackIDMapper()
        let fixture = await makeCoordinator(idMapper: mapper)
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 2021)
        let change = ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: "2021",
            newValue: "2023",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            try await fixture.coordinator.applyChange(change)
        }

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Reviewed mapped changes fail tracks without AppleScript IDs")
    func reviewedMappedChangesFailTracksWithoutAppleScriptIDs() async throws {
        let mapper = TrackIDMapper()
        let fixture = await makeCoordinator(idMapper: mapper)
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 2021)
        let change = ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: "2021",
            newValue: "2023",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [change],
                progressHandler: ignoreAcceptedChangeProgress
            )
        }

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Reviewed mapped changes fail on non-editable AppleScript metadata")
    func reviewedMappedChangesFailOnNonEditableAppleScriptMetadata() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeEditableTrack(id: "MK1", genre: "Rock", year: nil)
        let appleScriptTrack = Track(
            id: "AS1",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: "Rock",
            year: 1969,
            trackStatus: "prerelease",
            releaseYear: 2023
        )
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )
        let fixture = await makeCoordinator(idMapper: mapper)
        let change = ProposedChange(
            track: musicKitTrack,
            changeType: .yearUpdate,
            oldValue: nil,
            newValue: "2023",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [change],
                progressHandler: ignoreAcceptedChangeProgress
            )
        }

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Reviewed unavailable changes fail without writing")
    func reviewedUnavailableChangesFailWithoutWriting() async throws {
        let fixture = await makeCoordinator()
        let track = Track(
            id: "MK1",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: "Rock",
            year: 1969,
            trackStatus: "no longer available"
        )
        let change = ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [change],
                progressHandler: ignoreAcceptedChangeProgress
            )
        }

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    private func makeCoordinator(
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        idMapper: (any TrackIDMapping)? = nil
    ) async -> AcceptedApplyFixture {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorApplyAcceptedTests-\(UUID().uuidString)")
        let cache = MockCacheService()
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: undo,
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return AcceptedApplyFixture(coordinator: coordinator, bridge: bridge, cache: cache)
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

    private func makeEditableTrack(
        id: String,
        genre: String?,
        year: Int?
    ) -> Track {
        Track(
            id: id,
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: genre,
            year: year,
            trackStatus: nil
        )
    }
}

private func ignoreAcceptedChangeProgress(_ update: ProgressUpdate) {
    _ = update
}

private struct AcceptedApplyFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let cache: MockCacheService
}
