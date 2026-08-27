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
        ], certifiedArtists: ["Metallica"])

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: [" Metallica "])
        )

        #expect(load.tracks.map(\.id) == ["DB-1"])
        #expect(load.readiness.isReady)
    }

    @Test("A row without canonical database identity fails closed")
    func rejectsNoncanonicalRow() async {
        let store = LoaderTrackStore(tracks: [
            Track(id: "catalog-id", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
        ])

        await #expect(throws: LibraryLoadError.nonCanonicalMirror(trackID: "catalog-id")) {
            _ = try await LibraryTrackLoader.currentMirror(store: store, requirement: requirement())
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

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["In Flames"])
        )

        #expect(load.tracks.map(\.id) == ["DB-1"])
    }

    @Test("Empty uncertified mirror neither readies updates nor replaces cache")
    func uncertifiedMirrorNotReady() async throws {
        let store = LoaderTrackStore(tracks: [])

        let load = try await LibraryTrackLoader.currentMirror(store: store, requirement: requirement())

        #expect(load.tracks.isEmpty)
        #expect(!load.readiness.isReady)
    }

    @Test("Recovered unknown membership may replace presentation cache")
    func showsRecoveredMirror() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "In Flames")]
        )

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["In Flames"])
        )

        #expect(load.tracks.map(\.id) == ["DB-1"])
        #expect(!load.readiness.isReady)
    }

    @Test("Matching artist certificate readies that exact scope")
    func matchingScopeIsReady() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            certifiedArtists: ["Metallica"]
        )

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["metallica"])
        )

        #expect(load.readiness.isReady)
    }

    @Test("Broader artist certificate does not admit a requested subset")
    func artistSubsetIsUnready() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            certifiedArtists: ["Metallica", "Björk"]
        )

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["Metallica"])
        )

        #expect(!load.readiness.isReady)
    }

    @Test("Artist scope expansion remains unready")
    func expandedScopeIsUnready() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            certifiedArtists: ["Metallica"]
        )

        let load = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["Metallica", "Björk"])
        )

        #expect(!load.readiness.isReady)
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
            requirement: requirement(testArtists: ["Metallica"])
        )

        #expect(load.tracks.map(\.id) == ["DB-1", "DB-2"])
    }

    @Test("Full-library certificate readies only the exact full scope")
    func fullCertificateIsExact() async throws {
        let store = LoaderTrackStore(
            tracks: [canonicalTrack(id: "DB-1", artist: "Metallica")],
            certifiedArtists: []
        )

        let fullLoad = try await LibraryTrackLoader.currentMirror(store: store, requirement: requirement())
        let artistLoad = try await LibraryTrackLoader.currentMirror(
            store: store,
            requirement: requirement(testArtists: ["Metallica"])
        )

        #expect(fullLoad.readiness.isReady)
        #expect(!artistLoad.readiness.isReady)
    }
}

private actor LoaderTrackStore: TrackStateStore {
    private let tracks: [Track]
    private let presentIDs: Set<MusicDatabaseTrackID>
    private let repairCandidates: [Track]
    private let certifiedArtists: [String]?

    init(
        tracks: [Track],
        presentIDs: Set<MusicDatabaseTrackID>? = nil,
        repairCandidates: [Track] = [],
        certifiedArtists: [String]? = nil
    ) {
        self.tracks = tracks
        self.presentIDs = presentIDs ?? Set(tracks.compactMap(\.databaseID))
        self.repairCandidates = repairCandidates
        self.certifiedArtists = certifiedArtists
    }

    func initialize() async throws {
        // This in-memory loader store has no setup work.
    }
    func loadAllTracks() async throws -> [Track] {
        tracks
    }
    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        let ids = presentIDs.sorted { $0.rawValue < $1.rawValue }
        let membership = try testMembershipStamp(for: ids)
        let certificates: [ScopeCertificate] = certifiedArtists.map { artists in
            let fingerprint = "test-observation"
            return [ScopeCertificate(
                id: UUID(),
                revision: .initial,
                membership: membership,
                testArtists: artists,
                fieldSet: .processingV1,
                requestedFingerprint: fingerprint,
                observedFingerprint: fingerprint,
                trackCount: tracks.count,
                observedAt: Date()
            )]
        } ?? []
        return TrackMirrorSnapshot(
            revision: .initial,
            membershipStamp: membership,
            presentIDs: Set(ids),
            presentTracks: tracks,
            repairCandidates: repairCandidates,
            certificates: certificates
        )
    }
    @discardableResult
    func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        // Loader tests exercise reads only, so mirror writes are intentionally inert.
        try MirrorCommitResult(revision: commit.baseRevision.advanced())
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

private func requirement(testArtists: [String] = []) -> MirrorRequirement {
    MirrorRequirement(
        testArtists: testArtists,
        fieldSet: .processingV1,
        maximumMetadataAge: nil
    )
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
