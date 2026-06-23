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

    @Test("does not prefer exact pending key when aliases match another album identity")
    func doesNotPreferExactPendingKeyWhenAliasesMatchAnotherAlbumIdentity() {
        let tracks = [
            Track(
                id: "exact",
                name: "Shared Song",
                artist: "Guest Singer",
                album: "Greatest Hits"
            ),
            Track(
                id: "compilation",
                name: "Compilation Song",
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

    @Test("pending cleanup does not remove guest aliases for canonical albums")
    func pendingCleanupDoesNotRemoveGuestAliasesForCanonicalAlbums() {
        let track = Track(
            id: "one",
            name: "Shared Song",
            artist: "Guest Singer",
            album: "Greatest Hits",
            albumArtist: "Original Artist"
        )
        let entry = PendingAlbumEntry(
            id: "original-artist-greatest-hits",
            artist: "Original Artist",
            album: "Greatest Hits",
            reason: "suspicious_year_change"
        )

        let identities = WorkflowViewModel.pendingRemovalIdentities(entry: entry, albumTracks: [track])
        let identityPairs = Set(identities.map { "\($0.artist)|\($0.album)" })

        #expect(identityPairs.contains("Original Artist|Greatest Hits"))
        #expect(identityPairs.contains("Guest Singer|Greatest Hits") == false)
    }

    @Test("pending verification processes duplicate identity aliases once")
    func pendingVerificationProcessesDuplicateIdentityAliasesOnce() async throws {
        let canonicalEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let legacyEntry = PendingAlbumEntry(
            id: "daft-punk-feat-pharrell-williams-random-access-memories",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [canonicalEntry, legacyEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: [
            Track(
                id: "ram-1",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "ram-2",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories"
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID).sorted() == ["ram-1", "ram-2"])
        #expect(writes.count == 2)
        #expect(viewModel.completedEntries.map(\.trackID).sorted() == ["ram-1", "ram-2"])
        #expect(viewModel.processedCount == 2)
        #expect(await pendingVerification.verificationTimestampUpdateCount() == 1)
        #expect(removals.contains { $0.artist == "Daft Punk" && $0.album == "Random Access Memories" })
        #expect(removals.contains {
            $0.artist == "Daft Punk feat. Pharrell Williams" && $0.album == "Random Access Memories"
        })
    }

    @Test("pending verification enriches album identity before grouping")
    func pendingVerificationEnrichesAlbumIdentityBeforeGrouping() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let enrichedTracks = randomAccessMemoriesTracksWithAlbumArtist()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: enrichedTracks,
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: [
            Track(
                id: "ram-1",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "ram-2",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories"
            ),
        ])

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()

        #expect(writes.map(\.trackID).sorted() == ["as-ram-1", "as-ram-2"])
        #expect(viewModel.completedEntries.map(\.trackID).sorted() == ["ram-1", "ram-2"])
        #expect(viewModel.processedCount == 2)
    }

    @Test("pending verification processes sibling guest aliases once")
    func pendingVerificationProcessesSiblingGuestAliasesOnce() async throws {
        let pharrellEntry = PendingAlbumEntry(
            id: "pharrell-williams-random-access-memories",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let julianEntry = PendingAlbumEntry(
            id: "julian-casablancas-random-access-memories",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pharrellEntry, julianEntry])
        let enrichedTracks = randomAccessMemoriesTracksWithAlbumArtist()
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: enrichedTracks,
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()

        #expect(writes.map(\.trackID).sorted() == ["as-ram-1", "as-ram-2"])
        #expect(writes.count == 2)
        #expect(viewModel.completedEntries.map(\.trackID).sorted() == ["ram-1", "ram-2"])
        #expect(viewModel.processedCount == 2)
        #expect(removals.contains { $0.artist == "Pharrell Williams" && $0.album == "Random Access Memories" })
        #expect(removals.contains { $0.artist == "Julian Casablancas" && $0.album == "Random Access Memories" })
        #expect(remainingPending.isEmpty)
    }

    @Test("pending verification keeps album pending when AppleScript context is incomplete")
    func pendingVerificationKeepsAlbumPendingWhenAppleScriptContextIsIncomplete() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let loadedTracks = [
            Track(id: "deftones-1", name: "My Own Summer", artist: "Deftones", album: "Around the Fur"),
            Track(id: "deftones-2", name: "Be Quiet and Drive", artist: "Deftones", album: "Around the Fur"),
        ]
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 1997, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: [
                    Track(id: "deftones-1", name: "My Own Summer", artist: "Deftones", album: "Around the Fur"),
                ],
                appleScriptIDsByMusicKitID: [
                    "deftones-1": "as-deftones-1",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: loadedTracks)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.isEmpty)
        #expect(viewModel.trackStatuses["deftones-1"] != .queued)
        #expect(Set(viewModel.result?.failedTrackIDs ?? []) == ["deftones-1", "deftones-2"])
    }

    @Test("pending verification fails closed when collaboration context is incomplete")
    func pendingVerificationFailsClosedWhenCollaborationContextIsIncomplete() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: [
                    randomAccessMemoriesTracksWithAlbumArtist()[0],
                ],
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel
            .startPendingVerification(
                tracks: randomAccessMemoriesMusicKitTracks(secondArtist: "Daft Punk feat. Julian Casablancas")
            )

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()
        let report = UpdateRunReport(
            result: viewModel.result,
            completedEntries: viewModel.completedEntries,
            trackStatuses: viewModel.trackStatuses,
            tracks: randomAccessMemoriesMusicKitTracks(secondArtist: "Daft Punk feat. Julian Casablancas"),
            testArtists: []
        )

        #expect(writes.isEmpty)
        #expect(removals.isEmpty)
        #expect(viewModel.completedEntries.isEmpty)
        #expect(viewModel.trackStatuses["ram-1"] != .queued)
        #expect(Set(viewModel.result?.failedTrackIDs ?? []) == ["ram-1", "ram-2"])
        #expect(remainingPending.map(\.id) == ["daft-punk-random-access-memories"])
        #expect(viewModel.processedCount == 2)
        #expect(viewModel.totalCount == 2)
        #expect(viewModel.trackStatuses.count == 2)
        #expect(report.scannedTrackCount == 2)
    }

    @Test("pending verification ignores unrelated missing context with the same album title")
    func pendingVerificationIgnoresUnrelatedMissingContextWithSameAlbumTitle() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "artist-a-greatest-hits",
            artist: "Artist A",
            album: "Greatest Hits",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let loadedTracks = [
            Track(id: "artist-a-1", name: "Single A", artist: "Artist A", album: "Greatest Hits"),
            Track(id: "artist-b-1", name: "Single B", artist: "Artist B", album: "Greatest Hits"),
        ]
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2001, confidence: 100),
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: [
                    Track(id: "artist-a-1", name: "Single A", artist: "Artist A", album: "Greatest Hits"),
                ],
                appleScriptIDsByMusicKitID: [
                    "artist-a-1": "as-artist-a-1",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: loadedTracks)

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()

        #expect(writes.map(\.trackID) == ["as-artist-a-1"])
        #expect(removals.contains { $0.artist == "Artist A" && $0.album == "Greatest Hits" })
        #expect(viewModel.result?.failedTrackIDs.isEmpty == true)
    }

    @Test("partial pending verification marks no-op tracks done")
    func partialPendingVerificationMarksNoOpTracksDone() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            failingWriteTrackIDs: ["as-ram-2"],
            noChangeWriteTrackIDs: ["as-ram-1"],
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()

        #expect(viewModel.trackStatuses["ram-1"] == .done)
        if case let .failed(message) = viewModel.trackStatuses["ram-2"] {
            #expect(message.contains("script write failed"))
        } else {
            Issue.record("ram-2 should be marked failed")
        }
        #expect(removals.isEmpty)
        #expect(remainingPending.map(\.id) == ["daft-punk-random-access-memories"])
    }

    @Test("duplicate aliases are not retried after partial pending failure")
    func duplicateAliasesAreNotRetriedAfterPartialPendingFailure() async throws {
        let pharrellEntry = PendingAlbumEntry(
            id: "pharrell-williams-random-access-memories",
            artist: "Pharrell Williams",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let julianEntry = PendingAlbumEntry(
            id: "julian-casablancas-random-access-memories",
            artist: "Julian Casablancas",
            album: "Random Access Memories",
            reason: "suspicious_year_change"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pharrellEntry, julianEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            failingWriteTrackIDs: ["as-ram-2"],
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)
        let writes = await fixture.scriptClient.updatedProperties()
        let removals = await pendingVerification.removedAlbums()
        let remainingPending = await pendingVerification.getAllPendingAlbums()

        #expect(writes.map(\.trackID).count(where: { $0 == "as-ram-1" }) == 1)
        #expect(viewModel.result?.failedTrackIDs.count(where: { $0 == "ram-2" }) == 1)
        #expect(removals.isEmpty)
        #expect(Set(remainingPending.map(\.id)) == [
            "pharrell-williams-random-access-memories",
            "julian-casablancas-random-access-memories",
        ])
    }

    @Test("pending verification keeps per-track failure messages")
    func pendingVerificationKeepsPerTrackFailureMessages() async throws {
        let pendingEntry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let pendingVerification = WorkflowPendingVerificationService(entries: [pendingEntry])
        let fixture = makeWorkflowFixture(
            apiService: DashboardStateAPIService(year: 2013, confidence: 100),
            failingWriteTrackIDs: ["as-ram-1", "as-ram-2"],
            pendingVerificationService: pendingVerification,
            idMapper: WorkflowTrackIDMapper(
                enrichedTracks: randomAccessMemoriesTracksWithAlbumArtist(),
                appleScriptIDsByMusicKitID: [
                    "ram-1": "as-ram-1",
                    "ram-2": "as-ram-2",
                ]
            )
        )
        let viewModel = fixture.viewModel
        viewModel.mode = .pendingVerification

        viewModel.startPendingVerification(tracks: randomAccessMemoriesMusicKitTracks())

        try await waitForWorkflowToLeaveScanning(viewModel)

        if case let .failed(message) = viewModel.trackStatuses["ram-1"] {
            #expect(message.contains("ram-1"))
        } else {
            Issue.record("ram-1 should be marked failed")
        }
        if case let .failed(message) = viewModel.trackStatuses["ram-2"] {
            #expect(message.contains("ram-2"))
        } else {
            Issue.record("ram-2 should be marked failed")
        }
    }
}
