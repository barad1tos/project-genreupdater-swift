import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — reviewed write preflight")
struct ReviewedWritePreflightTests {
    @Test("Reviewed year update skips already-processed write metadata")
    func reviewedYearUpdateSkipsAlreadyProcessedWriteMetadata() async throws {
        let musicKitTrack = Track(
            id: "MK1",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: "Rock",
            year: 1969,
            trackStatus: nil
        )
        let processedTrack = Track(
            id: musicKitTrack.id,
            name: musicKitTrack.name,
            artist: musicKitTrack.artist,
            album: musicKitTrack.album,
            genre: musicKitTrack.genre,
            year: 1969,
            trackStatus: nil,
            yearBeforeMGU: 1968,
            yearSetByMGU: 1969,
            appleScriptID: "AS1"
        )
        let mapper = ProcessedReviewedTrackIDMapper(
            musicKitID: musicKitTrack.id,
            appleScriptID: "AS1",
            enrichedTrack: processedTrack
        )
        let fixture = await makeCoordinator(idMapper: mapper)
        let change = ProposedChange(
            track: musicKitTrack,
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
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
        #expect(result.noOpEntries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Generated year update still writes already-processed metadata")
    func generatedYearUpdateStillWritesAlreadyProcessedMetadata() async throws {
        let musicKitTrack = Track(
            id: "MK1",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: "Rock",
            year: 1969,
            trackStatus: nil
        )
        let processedTrack = Track(
            id: musicKitTrack.id,
            name: musicKitTrack.name,
            artist: musicKitTrack.artist,
            album: musicKitTrack.album,
            genre: musicKitTrack.genre,
            year: 1969,
            trackStatus: nil,
            yearBeforeMGU: 1968,
            yearSetByMGU: 1969,
            appleScriptID: "AS1"
        )
        let mapper = ProcessedReviewedTrackIDMapper(
            musicKitID: musicKitTrack.id,
            appleScriptID: "AS1",
            enrichedTrack: processedTrack
        )
        let fixture = await makeCoordinator(idMapper: mapper)
        let change = ProposedChange(
            track: musicKitTrack,
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        _ = try await fixture.coordinator.applyChange(change, isReviewedChange: false)

        let written = await fixture.bridge.writtenProperties
        #expect(written.map(\.trackID) == ["AS1"])
        #expect(written.map(\.property) == ["year"])
        #expect(written.map(\.value) == ["1970"])
    }

    private func makeCoordinator(idMapper: any TrackIDMapping) async -> ReviewedWritePreflightFixture {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCoordinatorReviewedWritePreflightTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
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
            yearDeterminator: YearDeterminator()
        )

        return ReviewedWritePreflightFixture(coordinator: coordinator, bridge: bridge)
    }
}

private func ignoreAcceptedChangeProgress(_ update: ProgressUpdate) {
    _ = update
}

private struct ReviewedWritePreflightFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private actor ProcessedReviewedTrackIDMapper: TrackIDMapping {
    private let musicKitID: String
    private let appleScriptIDValue: String
    private let enrichedTrack: Track

    init(musicKitID: String, appleScriptID: String, enrichedTrack: Track) {
        self.musicKitID = musicKitID
        appleScriptIDValue = appleScriptID
        self.enrichedTrack = enrichedTrack
    }

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        musicKitID == self.musicKitID ? appleScriptIDValue : nil
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        musicKitTrack.id == musicKitID ? enrichedTrack : nil
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        await Task.yield()
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        musicKitID == self.musicKitID
    }
}
