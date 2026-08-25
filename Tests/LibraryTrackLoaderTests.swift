import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("LibraryTrackLoader")
@MainActor
struct LibraryTrackLoaderTests {
    @Test("Current mirror load returns only canonical scoped rows")
    func loadsCanonicalMirrorScope() async throws {
        let store = LoaderTrackStore(tracks: [
            canonicalTrack(id: "DB-1", artist: "Metallica"),
            canonicalTrack(id: "DB-2", artist: "Björk"),
        ])

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            scopedArtists: [" Metallica "]
        )

        #expect(load.tracks.map(\.id) == ["DB-1"])
        #expect(load.isLibraryReadyForUpdates)
    }

    @Test("A catalog-shaped row contaminating the mirror fails closed")
    func rejectsNonCanonicalMirrorRow() async {
        let store = LoaderTrackStore(tracks: [
            Track(id: "catalog-id", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ])

        await #expect(throws: LibraryLoadError.nonCanonicalMirror(trackID: "catalog-id")) {
            _ = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: [])
        }
    }
}

private actor LoaderTrackStore: TrackStateStore {
    private let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func initialize() async throws {}
    func loadAllTracks() async throws -> [Track] {
        tracks
    }
    func applyMirror(_: TrackMirrorUpdate) async throws {}
    func getTrack(byID _: String) async throws -> Track? {
        nil
    }
    func persistAppliedChange(_: ChangeLogEntry) async throws {}
    func getUnprocessedTracks() async throws -> [Track] {
        []
    }
    func trackCount() async throws -> Int {
        tracks.count
    }
}

private func canonicalTrack(id: String, artist: String) -> Track {
    Track(
        id: id,
        name: "Song",
        artist: artist,
        album: "Album",
        appleScriptID: id
    )
}
