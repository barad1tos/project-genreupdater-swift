import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Library sync prerelease identity")
struct LibrarySyncPrereleaseTests {
    @Test("Resolves prerelease pending with album identity aliases")
    func resolvesPrereleasePendingWithAlbumIdentityAliases() async throws {
        let pendingVerification = PendingVerificationProbe(entries: [
            PendingAlbumEntry(
                id: "daft-punk",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
            PendingAlbumEntry(
                id: "daft-punk-feature",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
        ], isVerificationNeeded: false)
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        let service = await makeSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Random Access Memories"
        })
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk feat. Pharrell Williams" && removal.album == "Random Access Memories"
        })
    }

    @Test("Resolves prerelease pending when current status is unknown")
    func resolvesPrereleasePendingWhenCurrentStatusIsUnknown() async throws {
        let pendingVerification = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "future",
                artist: "Daft Punk",
                album: "Future Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: false
        )
        let storedTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk",
            album: "Future Album",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Future Song",
            artist: "Daft Punk",
            album: "Future Album",
            trackStatus: nil
        )
        let service = await makeSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Future Album"
        })
    }

    @Test("Keeps unrelated pending row after prerelease transition")
    func keepsUnrelatedPendingRowAfterPrereleaseTransition() async throws {
        let pendingVerification = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "pending",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
            isVerificationNeeded: false
        )
        let storedTrack = Track(
            id: "PRE",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        let service = await makeSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.isEmpty)
    }

    @Test("Removes resolved prerelease alias without touching unrelated pending alias")
    func removesResolvedPrereleaseAliasWithoutTouchingUnrelatedPendingAlias() async throws {
        let pendingVerification = PendingVerificationProbe(entries: [
            PendingAlbumEntry(
                id: "prerelease-alias",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
            PendingAlbumEntry(
                id: "year-alias",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
        ], isVerificationNeeded: false)
        let storedTrack = Track(
            id: "PRE",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let currentTrack = Track(
            id: "PRE",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        let service = await makeSyncService(
            storedTracks: [storedTrack],
            currentTracks: ["PRE": currentTrack],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.contains { removal in
            removal.artist == "Daft Punk" && removal.album == "Random Access Memories"
        })
        #expect(!removedAlbums.contains { removal in
            removal.artist == "Daft Punk feat. Pharrell Williams" && removal.album == "Random Access Memories"
        })
    }

    @Test("Keeps prerelease pending while a sibling album identity alias remains prerelease")
    func keepsPrereleasePendingWhileSiblingAlbumIdentityAliasRemainsPrerelease() async throws {
        let pendingVerification = PendingVerificationProbe(entry: nil, isVerificationNeeded: false)
        let transitionedStoredTrack = Track(
            id: "PRE-1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let remainingStoredTrack = Track(
            id: "PRE-2",
            name: "Instant Crush",
            artist: "Daft Punk feat. Julian Casablancas",
            album: "Random Access Memories",
            trackStatus: TrackKind.prerelease.rawValue,
            albumArtist: "Daft Punk"
        )
        let transitionedCurrentTrack = Track(
            id: "PRE-1",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            trackStatus: TrackKind.subscription.rawValue
        )
        let service = await makeSyncService(
            storedTracks: [transitionedStoredTrack, remainingStoredTrack],
            currentTracks: [
                "PRE-1": transitionedCurrentTrack,
                "PRE-2": remainingStoredTrack,
            ],
            pendingVerification: pendingVerification
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)

        let removedAlbums = await pendingVerification.removedAlbums
        #expect(removedAlbums.isEmpty)
    }

    private func makeSyncService(
        storedTracks: [Track],
        currentTracks: [String: Track],
        pendingVerification: PendingVerificationProbe
    ) async -> LibrarySyncService {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        await bridge.setLibrary(ids: currentTracks.keys.sorted(), tracks: currentTracks)
        await store.setStored(storedTracks)
        return LibrarySyncService(
            trackStore: store,
            pendingVerificationService: pendingVerification,
            observer: bridge
        )
    }
}
