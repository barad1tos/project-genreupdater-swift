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

    @Test("Reviewed mapped changes skip tracks without AppleScript IDs")
    func reviewedMappedChangesSkipTracksWithoutAppleScriptIDs() async throws {
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

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: ignoreAcceptedChangeProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Reviewed mapped changes use AppleScript metadata before writing")
    func reviewedMappedChangesUseAppleScriptMetadataBeforeWriting() async throws {
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

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: ignoreAcceptedChangeProgress
        )

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
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
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: MockCacheService(),
                undoCoordinator: undo,
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return AcceptedApplyFixture(coordinator: coordinator, bridge: bridge)
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
}
