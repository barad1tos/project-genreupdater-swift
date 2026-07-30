import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — reviewed write preflight")
struct WritePreflightTests {
    @Test("Reviewed year update skips already-processed write metadata")
    func reviewedYearSkipsProcessed() async throws {
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
        let mapper = ProcessedIDMapper(
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
        #expect(result.noOpEntries.count == 1)
        #expect(result.noOpEntries.first?.trackID == musicKitTrack.id)
        #expect(result.noOpEntries.first?.changeType == .yearUpdate)
        #expect(result.noOpEntries.first?.oldYear == 1970)
        #expect(result.noOpEntries.first?.newYear == 1970)
        #expect(result.failedTrackIDs.isEmpty)
    }

    @Test("Reviewed genre update fails when current metadata changed externally")
    func reviewedGenreRejectsStale() async throws {
        let musicKitTrack = Track(
            id: "MK1",
            name: "Come Together",
            artist: "Beatles",
            album: "Abbey Road",
            genre: "Rock",
            year: 1969,
            trackStatus: nil
        )
        let currentTrack = Track(
            id: musicKitTrack.id,
            name: musicKitTrack.name,
            artist: musicKitTrack.artist,
            album: musicKitTrack.album,
            genre: "Jazz",
            year: 1969,
            trackStatus: nil,
            appleScriptID: "AS1"
        )
        let mapper = ProcessedIDMapper(
            musicKitID: musicKitTrack.id,
            appleScriptID: "AS1",
            enrichedTrack: currentTrack
        )
        let fixture = await makeCoordinator(idMapper: mapper)
        let change = ProposedChange(
            track: musicKitTrack,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Art Pop",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [change],
                progressHandler: ignoreAcceptedChangeProgress
            )
            Issue.record("Expected stale reviewed change failure")
        } catch let error as UpdateCoordinatorError {
            #expect(error.errorDescription?.contains("reviewed value no longer matches Music.app") == true)
        }

        let written = await fixture.bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Generated year update still writes already-processed metadata")
    func generatedYearWritesProcessed() async throws {
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
        let mapper = ProcessedIDMapper(
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

    @Test("Reviewed batch write uses configured ID fetch batch size")
    func chunksIDFetches() async throws {
        let changes = batchChanges()
        let mapper = batchMapper(for: changes)
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            areBatchUpdatesEnabled: true,
            maxBatchUpdateSize: 5,
            idsBatchSize: 2
        )
        let fixture = await makeCoordinator(idMapper: mapper, runtimeConfiguration: runtimeConfiguration)
        await fixture.bridge.setFetchedTracks(scriptTracks(for: changes))

        let result = try await fixture.coordinator.applyAcceptedChanges(
            changes,
            progressHandler: ignoreAcceptedChangeProgress
        )

        let fetchCalls = await fixture.bridge.fetchTracksByIDsCalls()
        #expect(fetchCalls.map(\.batchSize).allSatisfy { $0 == 2 })
        #expect(result.entries.count == 3)
        #expect(result.failedTrackIDs.isEmpty)
    }

    private func batchChanges() -> [ProposedChange] {
        (1 ... 3).map { index in
            ProposedChange(
                track: Track(
                    id: "MK\(index)",
                    name: "Track \(index)",
                    artist: "Beatles",
                    album: "Abbey Road",
                    year: 1969,
                    trackStatus: nil
                ),
                changeType: .yearUpdate,
                oldValue: "1969",
                newValue: "1970",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: true
            )
        }
    }

    private func batchMapper(for changes: [ProposedChange]) -> BatchIDMapper {
        BatchIDMapper(changes.map { change in
            let musicKitID = change.track.id
            let appleScriptID = scriptID(for: change.track)
            return (
                musicKitID: musicKitID,
                appleScriptID: appleScriptID,
                enrichedTrack: mutationTrack(from: change.track, appleScriptID: appleScriptID)
            )
        })
    }

    private func scriptTracks(for changes: [ProposedChange]) -> [Track] {
        changes.map { change in
            let appleScriptID = scriptID(for: change.track)
            return Track(
                id: appleScriptID,
                name: change.track.name,
                artist: change.track.artist,
                album: change.track.album,
                year: 1969,
                trackStatus: nil,
                appleScriptID: appleScriptID
            )
        }
    }

    private func mutationTrack(from track: Track, appleScriptID: String) -> Track {
        Track(
            id: track.id,
            name: track.name,
            artist: track.artist,
            album: track.album,
            year: 1969,
            trackStatus: nil,
            appleScriptID: appleScriptID
        )
    }

    private func scriptID(for track: Track) -> String {
        track.id.replacingOccurrences(of: "MK", with: "AS")
    }

    private func makeCoordinator(
        idMapper: any TrackIDMapping,
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) async -> PreflightFixture {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WritePreflightTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: undo,
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return PreflightFixture(coordinator: coordinator, bridge: bridge)
    }
}

private func ignoreAcceptedChangeProgress(_ update: ProgressUpdate) {
    _ = update
}

private struct PreflightFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private actor ProcessedIDMapper: TrackIDMapping {
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

private actor BatchIDMapper: TrackIDMapping {
    private let valuesByMusicKitID: [String: (appleScriptID: String, enrichedTrack: Track)]

    init(_ values: [(musicKitID: String, appleScriptID: String, enrichedTrack: Track)]) {
        valuesByMusicKitID = Dictionary(
            uniqueKeysWithValues: values.map {
                ($0.musicKitID, (appleScriptID: $0.appleScriptID, enrichedTrack: $0.enrichedTrack))
            }
        )
    }

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        valuesByMusicKitID[musicKitID]?.appleScriptID
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        valuesByMusicKitID[musicKitTrack.id]?.enrichedTrack
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        await Task.yield()
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        valuesByMusicKitID[musicKitID] != nil
    }
}
