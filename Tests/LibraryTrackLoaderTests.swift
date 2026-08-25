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

    @Test("A row without canonical database identity fails closed")
    func rejectsNoncanonicalRow() async {
        let store = LoaderTrackStore(tracks: [
            Track(id: "catalog-id", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ])

        await #expect(throws: LibraryLoadError.nonCanonicalMirror(trackID: "catalog-id")) {
            _ = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: [])
        }
    }

    @Test("An unseeded empty mirror is not update-ready")
    func unseededNotReady() async throws {
        let store = LoaderTrackStore(tracks: [], isSeeded: false)

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: [])

        #expect(load.tracks.isEmpty)
        #expect(!load.isLibraryReadyForUpdates)
    }
}

private actor LoaderTrackStore: TrackStateStore {
    private let tracks: [Track]
    private let isSeeded: Bool

    init(tracks: [Track], isSeeded: Bool = true) {
        self.tracks = tracks
        self.isSeeded = isSeeded
    }

    func initialize() async throws {
        // This in-memory loader store has no setup work.
    }
    func loadAllTracks() async throws -> [Track] {
        tracks
    }
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(tracks: tracks, isSeeded: isSeeded)
    }
    func applyMirror(_: TrackMirrorUpdate) async throws {
        // Loader tests exercise reads only, so mirror writes are intentionally inert.
    }
    func getTrack(byID _: String) async throws -> Track? {
        nil
    }
    func persistAppliedChange(_: ChangeLogEntry) async throws {
        // Loader tests exercise reads only, so applied changes are intentionally inert.
    }
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
