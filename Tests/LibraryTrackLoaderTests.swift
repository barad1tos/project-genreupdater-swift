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
        ], coverage: .verified(.fullLibrary))

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

    @Test("Current mirror load excludes legacy repair candidates from the library")
    func excludesRepairCandidates() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "In Flames")],
            repairCandidates: [
                Track(
                    id: "catalog-id",
                    name: "Only for the Weak",
                    artist: "In Flames",
                    album: "Clayman",
                    appleScriptID: "DB-1"
                ),
            ]
        )

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: ["In Flames"])

        #expect(load.tracks.map(\.id) == ["DB-1"])
    }

    @Test("Empty unknown mirror neither readies updates nor replaces cache")
    func unknownCoverageNotReady() async throws {
        let store = LoaderTrackStore(tracks: [], coverage: .unknown)

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: [])

        #expect(load.tracks.isEmpty)
        #expect(!load.isLibraryReadyForUpdates)
    }

    @Test("Recovered unknown membership may replace presentation cache")
    func showsRecoveredMirror() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "In Flames")],
            coverage: .unknown
        )

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: ["In Flames"])

        #expect(load.tracks.map(\.id) == ["DB-1"])
        #expect(!load.isLibraryReadyForUpdates)
    }

    @Test("Matching artist coverage readies that artist scope")
    func matchingScopeIsReady() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            coverage: .verified(MirrorScope(testArtists: ["Metallica"]))
        )

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: ["metallica"])

        #expect(load.isLibraryReadyForUpdates)
    }

    @Test("Broader artist coverage readies a requested subset")
    func artistSubsetIsReady() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            coverage: .verified(MirrorScope(testArtists: ["Metallica", "Björk"]))
        )

        let load = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: ["Metallica"])

        #expect(load.isLibraryReadyForUpdates)
    }

    @Test("Artist scope expansion remains unready")
    func expandedScopeIsUnready() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            coverage: .verified(MirrorScope(testArtists: ["Metallica"]))
        )

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            scopedArtists: ["Metallica", "Björk"]
        )

        #expect(!load.isLibraryReadyForUpdates)
    }

    @Test("Cache supplements metadata only for IDs confirmed by membership")
    func cacheSupplementsPresentMembership() async throws {
        let firstID = try #require(MusicDatabaseTrackID(rawValue: "DB-1"))
        let secondID = try #require(MusicDatabaseTrackID(rawValue: "DB-2"))
        let outsideScopeID = try #require(MusicDatabaseTrackID(rawValue: "DB-OTHER"))
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: firstID.rawValue, artist: "Metallica")],
            presentIDs: [firstID, secondID, outsideScopeID]
        )
        let cachedTracks = [
            canonicalTrack(id: secondID.rawValue, artist: "Metallica"),
            canonicalTrack(id: outsideScopeID.rawValue, artist: "Other"),
            canonicalTrack(id: "DB-REMOVED", artist: "Metallica"),
        ]

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            cachedTracks: cachedTracks,
            scopedArtists: ["Metallica"]
        )

        #expect(load.tracks.map(\.id) == ["DB-1", "DB-2"])
    }

    @Test("Full-library coverage readies every requested scope")
    func fullCoverageIsReady() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            coverage: .verified(.fullLibrary)
        )

        let fullLoad = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: [])
        let artistLoad = try await LibraryTrackLoader.currentMirror(store: store, scopedArtists: ["Metallica"])

        #expect(fullLoad.isLibraryReadyForUpdates)
        #expect(artistLoad.isLibraryReadyForUpdates)
    }
}

private actor LoaderTrackStore: TrackStateStore {
    private let tracks: [Track]
    private let presentIDs: Set<MusicDatabaseTrackID>
    private let repairCandidates: [Track]
    private let coverage: MirrorCoverage

    init(
        tracks: [Track],
        presentIDs: Set<MusicDatabaseTrackID>? = nil,
        repairCandidates: [Track] = [],
        coverage: MirrorCoverage = .verified(.fullLibrary)
    ) {
        self.tracks = tracks
        self.presentIDs = presentIDs ?? Set(tracks.compactMap(\.databaseID))
        self.repairCandidates = repairCandidates
        self.coverage = coverage
    }

    func initialize() async throws {
        // This in-memory loader store has no setup work.
    }
    func loadAllTracks() async throws -> [Track] {
        tracks
    }
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        let ids = presentIDs.sorted { $0.rawValue < $1.rawValue }
        return try TrackMirrorSnapshot(
            revision: .initial,
            membershipStamp: testMembershipStamp(for: ids),
            presentIDs: Set(ids),
            presentTracks: tracks,
            repairCandidates: repairCandidates,
            coverage: coverage
        )
    }
    @discardableResult
    func applyMirror(_ update: TrackMirrorUpdate) async throws -> MirrorRevision {
        // Loader tests exercise reads only, so mirror writes are intentionally inert.
        try update.baseRevision.advanced()
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
