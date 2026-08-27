import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Projection runtime library loading")
@MainActor
struct ProjectionRuntimeLibraryTests {
    @Test("the backend load chain publishes library facts headlessly")
    func backendLoadPublishesLibraryFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let track = canonicalMirrorTrack(Core.Track(
            id: "t",
            name: "Song",
            artist: "Clutch",
            album: "Blast Tyrant",
            genre: "Rock",
            year: 2004
        ))
        await fixture.snapshotService.installSnapshot([track])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [track]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var appliedCounts: [Int] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            appliedCounts.append(tracks.count)
        }
        var browseApplications: [(count: Int, isCurrent: Bool)] = []
        fixture.dependencies.applyBrowseTruthForLoad = { tracks, _, token in
            browseApplications.append((tracks.count, fixture.dependencies.libraryLoadGate.isCurrent(token)))
        }

        await fixture.dependencies.loadLibrary()

        // Facts land on the dependency graph, the projection republishes
        // from the SAME values, and BOTH host callbacks fire with the
        // landed tracks (the PR-A scope-preview ledger pin + the browse
        // application seam).
        #expect(fixture.dependencies.libraryTracks.count == 1)
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
        let published = await fixture.dependencies.projectionStore.activityProjection()
        #expect(published.healthFacts.counts.totalTracks == 1)
        #expect(appliedCounts == [1])
        let browseCounts = browseApplications.map(\.count)
        let browseAllCurrent = browseApplications.allSatisfy(\.isCurrent)
        #expect(browseCounts == [1])
        #expect(browseAllCurrent)
    }

    @Test("a scope change synchronously empties library truth")
    func scopeChangeEmptiesLibraryTruth() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let track = canonicalMirrorTrack(Core.Track(
            id: "t",
            name: "Song",
            artist: "Clutch",
            album: "Blast Tyrant"
        ))
        await fixture.snapshotService.installSnapshot([track])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [track]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        await fixture.dependencies.loadLibrary()
        #expect(!fixture.dependencies.libraryTracks.isEmpty)

        fixture.dependencies.invalidateLibraryLoads()
        fixture.dependencies.emptyLibraryTruthForScopeChange()

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.libraryMetrics == nil)
        #expect(fixture.dependencies.lastLibraryScanDate == nil)
        #expect(!fixture.dependencies.isLibraryLoading)
        let republished = await fixture.dependencies.republishActivityProjection()
        #expect(republished.healthFacts.counts.totalTracks == 0)
    }

    @Test("a mid-flight invalidation drops the stale load's facts")
    func inFlightInvalidationDropsStaleFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let gate = LibraryReadGate()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(
                tracks: [canonicalMirrorTrack(Core.Track(
                    id: "stale",
                    name: "Old Scope",
                    artist: "Stale",
                    album: "Stale"
                ))],
                beforeLoad: { await gate.hold() }
            ),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        let load = Task { await fixture.dependencies.loadLibrary() }
        await gate.waitUntilRequested()
        fixture.dependencies.invalidateLibraryLoads()
        fixture.dependencies.emptyLibraryTruthForScopeChange()
        await gate.release()
        await load.value

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.lastLibraryScanDate == nil)
    }

    @Test("a workflow-only refresh preserves library truth")
    func workflowOnlyRefreshPreservesLibraryTruth() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let track = canonicalMirrorTrack(Core.Track(
            id: "t",
            name: "Song",
            artist: "Clutch",
            album: "Blast Tyrant"
        ))
        await fixture.snapshotService.installSnapshot([track])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [track]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        await fixture.dependencies.loadLibrary()

        fixture.dependencies.workflowFactsProvider = {
            ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        }
        let published = await fixture.dependencies.republishActivityProjection()

        #expect(published.healthFacts.counts.totalTracks == 1)
        #expect(fixture.dependencies.libraryTracks.count == 1)
    }

    @Test("an invalidation during browse application drops late writes")
    func invalidationDuringBrowseApplicationDropsLateWrites() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [
                canonicalMirrorTrack(Core.Track(
                    id: "live",
                    name: "Song",
                    artist: "Clutch",
                    album: "Blast Tyrant"
                )),
            ]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        fixture.dependencies.applyBrowseTruthForLoad = { _, readSource, _ in
            if case .cachedMirror = readSource {
                fixture.dependencies.invalidateLibraryLoads()
            }
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.lastLibraryScanDate == nil)
        #expect(fixture.dependencies.libraryMetrics == nil)
    }

    @Test("a cancelled mirror load does not publish unverified cache rows")
    func cancelledMirrorLoadIsNotAnError() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let analytics = try await installAnalytics(on: fixture.dependencies)
        await fixture.snapshotService.installSnapshot([
            canonicalMirrorTrack(Core.Track(
                id: "cached",
                name: "Song",
                artist: "Clutch",
                album: "Blast Tyrant"
            )),
        ])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(beforeLoad: { throw CancellationError() }),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(!fixture.dependencies.isLibraryLoading)
        let row = try #require(await analytics.projection(for: .currentSession).operations.first {
            $0.operationValue == AnalyticsOperation.libraryLoad.rawValue
        })
        #expect(row.calls == 1)
        #expect(row.succeeded == 0)
        #expect(row.cancelled == 1)
    }

    @Test("a mirror-load failure does not publish unverified cache rows")
    func loadFailureDoesNotPublishCache() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let analytics = try await installAnalytics(on: fixture.dependencies)
        await fixture.snapshotService.installSnapshot([
            canonicalMirrorTrack(Core.Track(
                id: "cached",
                name: "Song",
                artist: "Clutch",
                album: "Blast Tyrant"
            )),
        ])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(beforeLoad: {
                throw MusicLibraryError.fetchFailed(detail: "stubbed mirror failure")
            }),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryLoadError != nil)
        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(!fixture.dependencies.isLibraryLoading)
        let row = try #require(await analytics.projection(for: .currentSession).operations.first {
            $0.operationValue == AnalyticsOperation.libraryLoad.rawValue
        })
        #expect(row.calls == 1)
        #expect(row.succeeded == 0)
        #expect(row.failed == 1)
    }

    @Test("a contaminated cache is ignored when the current mirror is canonical")
    func contaminatedCacheDoesNotBlockCurrentMirror() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "cached-contamination", name: "Cached", artist: "Clutch", album: "Blast Tyrant"),
        ])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(
                tracks: [
                    canonicalMirrorTrack(Core.Track(
                        id: "current",
                        name: "Current",
                        artist: "Clutch",
                        album: "Blast Tyrant"
                    )),
                ],
                certifiedArtists: []
            ),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var browsedTrackIDs: [[String]] = []
        fixture.dependencies.applyBrowseTruthForLoad = { tracks, _, _ in
            browsedTrackIDs.append(tracks.map(\.id))
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["current"])
        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(fixture.dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [["current"]])
    }

    @Test("current contamination remains explicit when the cache is also contaminated")
    func currentContaminationWinsOverCachedContamination() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "cached-contamination", name: "Cached", artist: "Clutch", album: "Blast Tyrant"),
        ])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [
                Core.Track(id: "current-contamination", name: "Current", artist: "Clutch", album: "Blast Tyrant"),
            ]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.libraryLoadError == .nonCanonicalMirror(trackID: "current-contamination"))
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
    }

    @Test("request tokens invalidate across begins")
    func requestTokenGateTruthTable() {
        let gate = RequestTokenGate()

        let first = gate.begin()
        #expect(gate.isCurrent(first))

        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))

        gate.invalidate()
        #expect(!gate.isCurrent(second))
    }
}

@MainActor
private func installAnalytics(on dependencies: AppDependencies) async throws -> AnalyticsRecorder {
    var configuration = AnalyticsConfig()
    configuration.enabled = true
    let store = try GRDBCacheService.createInMemory()
    try await store.initialize()
    let recorder = AnalyticsRecorder(store: store, configuration: configuration)
    await recorder.initialize()
    dependencies.installTestAnalyticsRecorder(recorder)
    return recorder
}

private actor LibraryReadGate {
    private var requested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if requested {
            return
        }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func hold() async {
        requested = true
        requestContinuation?.resume()
        requestContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
