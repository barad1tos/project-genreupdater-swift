import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService — read-provider removals")
struct LibrarySyncRemovalTests {
    @Test("Keeps confirmed unmapped removals when mapped verification is empty")
    func keepsConfirmedUnmappedRemovalsWhenMappedVerificationIsEmpty() async throws {
        let bridge = QueuedFetchAllTrackIDsScriptClient(
            fetchAllTrackIDsResults: [
                [],
            ],
            tracksByID: [
                "AS-other": Track(
                    id: "AS-other",
                    name: "Other",
                    artist: "A",
                    album: "B",
                    appleScriptID: "AS-other"
                ),
            ]
        )
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([
            Track(id: "MK-current", name: "Current", artist: "A", album: "B"),
        ])
        await store.setStored([
            Track(id: "MK-current", name: "Current", artist: "A", album: "B"),
            Track(id: "MK-removed", name: "Removed", artist: "A", album: "B"),
            Track(
                id: "MK-mapped-removed",
                name: "Mapped",
                artist: "A",
                album: "B",
                appleScriptID: "AS-mapped"
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            readProvider: readProvider
        )

        let result = try await service.synchronizeNow()
        let remainingIDs = try await store.loadAllTracks().map(\.id).sorted()

        #expect(result.removedTrackIDs == ["MK-removed"])
        #expect(remainingIDs == ["MK-current", "MK-mapped-removed"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 1)
    }
}

private actor QueuedFetchAllTrackIDsScriptClient: AppleScriptClient {
    private var fetchAllTrackIDsResults: [[String]]
    private let tracksByID: [String: Track]
    private var fetchAllTrackIDsCalls = 0

    init(fetchAllTrackIDsResults: [[String]], tracksByID: [String: Track]) {
        self.fetchAllTrackIDsResults = fetchAllTrackIDsResults
        self.tracksByID = tracksByID
    }

    func initialize() async throws {}

    func runScript(name: String, arguments: [String], timeout _: Duration?) async throws -> String? {
        guard name == "fetch_tracks" else { return nil }

        let artist = arguments.first?.lowercased()
        let tracks = tracksByID.values.filter { track in
            guard let artist else { return true }
            return track.artist.lowercased() == artist || track.albumArtist?.lowercased() == artist
        }
        guard !tracks.isEmpty else { return "NO_TRACKS_FOUND" }
        return tracks.map(Self.appleScriptRecord).joined(separator: String(Track.recordSeparator))
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize _: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        fetchAllTrackIDsCalls += 1
        guard !fetchAllTrackIDsResults.isEmpty else { return [] }
        return fetchAllTrackIDsResults.removeFirst()
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        .changed
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {}

    func fetchAllTrackIDsCallCount() -> Int {
        fetchAllTrackIDsCalls
    }

    private static func appleScriptRecord(_ track: Track) -> String {
        [
            track.appleScriptID ?? track.id,
            track.name,
            track.artist,
            track.albumArtist ?? "",
            track.album,
            track.genre ?? "",
            "",
            "",
            track.trackStatus ?? "",
            track.year.map(String.init) ?? "",
            track.releaseYear.map(String.init) ?? "",
            "",
        ].joined(separator: String(Track.fieldSeparator))
    }
}
