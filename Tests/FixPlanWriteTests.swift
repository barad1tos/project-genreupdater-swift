import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("FixPlanWrite")
struct FixPlanWriteTests {
    @Test("reviewed write ID refresh uses configured batch size")
    func usesWriteIDBatchSize() async throws {
        let scriptClient = WriteIDScriptSpy()
        let mapper = TrackIDMapper()
        let changes = (1 ... 3).map { index in
            ProposedChange(
                track: musicKitTrack(index: index),
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Metal",
                confidence: 90,
                source: "review-test"
            )
        }
        await scriptClient.setTracks(changes.map { appleScriptTrack(from: $0.track) })

        try await FixPlanWrite.prepareWriteIDs(
            for: changes,
            mapper: mapper,
            scriptClient: scriptClient,
            writeIDBatchSize: 2
        )

        let calls = await scriptClient.fetchCalls
        #expect(calls.map(\.batchSize) == [2])
        #expect(Set(calls.flatMap(\.trackIDs)) == ["AS-1", "AS-2", "AS-3"])
        for index in 1 ... 3 {
            #expect(await mapper.appleScriptID(forMusicKitID: "MK-\(index)") == "AS-\(index)")
        }
    }
}

private actor WriteIDScriptSpy: AppleScriptClient {
    private var tracksByID: [String: Track] = [:]
    private(set) var initializeCount = 0
    private(set) var fetchCalls: [(trackIDs: [String], batchSize: Int)] = []
    private(set) var batchUpdates: [[(trackID: String, property: String, value: String)]] = []

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func initialize() async throws {
        initializeCount += 1
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
        timeout _: Duration?
    ) async throws -> [Track] {
        fetchCalls.append((trackIDs, batchSize))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        Array(tracksByID.keys)
    }

    func fetchTracks(artist _: String?, timeout _: Duration?) async throws -> [Track] {
        Array(tracksByID.values)
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        .noChange
    }

    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        batchUpdates.append(updates)
    }
}

private func musicKitTrack(index: Int) -> Track {
    Track(
        id: "MK-\(index)",
        name: "Track \(index)",
        artist: "Artist",
        album: "Album",
        appleScriptID: "AS-\(index)"
    )
}

private func appleScriptTrack(from track: Track) -> Track {
    Track(
        id: track.appleScriptID ?? track.id,
        name: track.name,
        artist: track.artist,
        album: track.album,
        appleScriptID: track.appleScriptID
    )
}
