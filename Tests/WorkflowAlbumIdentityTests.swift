import Core
import Testing
@testable import Genre_Updater

@Suite("Workflow album identity")
@MainActor
struct WorkflowAlbumIdentityTests {
    @Test("groups collaboration tracks by album artist")
    func groupsCollaborationTracksByAlbumArtist() throws {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)
        let group = try #require(groups[AlbumIdentity.key(for: tracks[0])])

        #expect(groups.count == 1)
        #expect(Set(group.map(\.id)) == ["one", "two"])
    }

    @Test("groups collaboration tracks by primary artist when album artist is missing")
    func groupsCollaborationTracksByPrimaryArtistWhenAlbumArtistIsMissing() throws {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)
        let group = try #require(groups[AlbumIdentity.key(for: tracks[0])])

        #expect(groups.count == 1)
        #expect(Set(group.map(\.id)) == ["one", "two"])
    }

    @Test("keeps different album artists separate")
    func keepsDifferentAlbumArtistsSeparate() {
        let tracks = [
            Track(
                id: "one",
                name: "Shared Song",
                artist: "Guest Artist",
                album: "Shared Album",
                albumArtist: "First Artist"
            ),
            Track(
                id: "two",
                name: "Other Song",
                artist: "Guest Artist",
                album: "Shared Album",
                albumArtist: "Second Artist"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        #expect(groups.count == 2)
        #expect(groups[AlbumIdentity.key(for: tracks[0])]?.map(\.id) == ["one"])
        #expect(groups[AlbumIdentity.key(for: tracks[1])]?.map(\.id) == ["two"])
    }

    @Test("keeps ampersand artists separate when album artist is missing")
    func keepsAmpersandArtistsSeparateWhenAlbumArtistIsMissing() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk & Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk & Julian Casablancas",
                album: "Random Access Memories"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        #expect(groups.count == 2)
        #expect(groups[AlbumIdentity.key(for: tracks[0])]?.map(\.id) == ["one"])
        #expect(groups[AlbumIdentity.key(for: tracks[1])]?.map(\.id) == ["two"])
    }

    @Test("matches pending entries with album identity")
    func matchesPendingEntriesWithAlbumIdentity() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entries = [
            PendingAlbumEntry(
                id: "daft-punk-random-access-memories",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
        ]

        let matchingTracks = WorkflowViewModel.tracksMatchingPendingEntries(tracks, entries: entries)

        #expect(Set(matchingTracks.map(\.id)) == ["one", "two"])
    }

    @Test("matches legacy pending entries with album identity aliases")
    func matchesLegacyPendingEntriesWithAlbumIdentityAliases() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entries = [
            PendingAlbumEntry(
                id: "daft-punk-feat-pharrell-williams-random-access-memories",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "suspicious_year_change"
            ),
        ]

        let matchingTracks = WorkflowViewModel.tracksMatchingPendingEntries(tracks, entries: entries)

        #expect(Set(matchingTracks.map(\.id)) == ["one", "two"])
    }

    @Test("resolves legacy pending entry to canonical album group")
    func resolvesLegacyPendingEntryToCanonicalAlbumGroup() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entry = PendingAlbumEntry(
            id: "daft-punk-feat-pharrell-williams-random-access-memories",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        let albumTracks = WorkflowViewModel.pendingAlbumTracks(for: entry, in: groups)

        #expect(Set(albumTracks.map(\.id)) == ["one", "two"])
    }

    @Test("resolves guest pending entry through track-side album artist aliases")
    func resolvesGuestPendingEntryThroughTrackSideAlbumArtistAliases() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entry = PendingAlbumEntry(
            id: "pharrell-williams-random-access-memories",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        let matchingTracks = WorkflowViewModel.tracksMatchingPendingEntries(tracks, entries: [entry])
        let albumTracks = WorkflowViewModel.pendingAlbumTracks(for: entry, in: groups)

        #expect(matchingTracks.map(\.id) == ["one"])
        #expect(albumTracks.map(\.id) == ["one"])
    }

    @Test("resolves guest pending entry to full canonical album group")
    func resolvesGuestPendingEntryToFullCanonicalAlbumGroup() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entry = PendingAlbumEntry(
            id: "pharrell-williams-random-access-memories",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        let albumTracks = WorkflowViewModel.pendingAlbumTracks(for: entry, in: groups)

        #expect(albumTracks.map(\.id) == ["one", "two"])
    }

    @Test("does not resolve ambiguous guest pending entry across album identities")
    func doesNotResolveAmbiguousGuestPendingEntryAcrossAlbumIdentities() {
        let tracks = [
            Track(
                id: "one",
                name: "Shared Song",
                artist: "Guest Singer",
                album: "Greatest Hits",
                albumArtist: "Original Artist"
            ),
            Track(
                id: "two",
                name: "Other Shared Song",
                artist: "Guest Singer",
                album: "Greatest Hits",
                albumArtist: "Compilation Artist"
            ),
        ]
        let entry = PendingAlbumEntry(
            id: "guest-singer-greatest-hits",
            artist: "Guest Singer",
            album: "Greatest Hits",
            reason: "suspicious_year_change"
        )
        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        let matchingTracks = WorkflowViewModel.tracksMatchingPendingEntries(tracks, entries: [entry])
        let albumTracks = WorkflowViewModel.pendingAlbumTracks(for: entry, in: groups)

        #expect(matchingTracks.isEmpty)
        #expect(albumTracks.isEmpty)
    }

    @Test("pending cleanup includes entry and track album identity aliases")
    func pendingCleanupIncludesEntryAndTrackAlbumIdentityAliases() {
        let track = Track(
            id: "one",
            name: "Get Lucky",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            albumArtist: "Daft Punk"
        )
        let entry = PendingAlbumEntry(
            id: "pharrell-williams-random-access-memories",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )

        let identities = WorkflowViewModel.pendingRemovalIdentities(entry: entry, albumTracks: [track])
        let identityPairs = Set(identities.map { "\($0.artist)|\($0.album)" })

        #expect(identityPairs.contains("Pharrell Williams|Random Access Memories"))
        #expect(identityPairs.contains("Daft Punk|Random Access Memories"))
    }
}
