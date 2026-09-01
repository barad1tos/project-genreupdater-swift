import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Projection runtime library loading")
@MainActor
struct ProjectionRuntimeLibraryTests {
    enum NonReadyEvidence: Sendable {
        case incomplete
        case stale
        case unavailable
    }

    @Test("mirror projection refresh leaves the physical catalog to its own load chain")
    func mirrorRefreshPreservesCatalog() async throws {
        let catalog = CatalogProbe(tracks: [
            catalogTrack(id: "OLD", title: "Old Song", artist: "Old Artist", album: "Old Album"),
        ])
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            musicCatalog: catalog
        )
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            runRecordStore: RunRecordStoreStub(),
            cache: cache
        )
        dependencies.applyBrowseTruth = { [weak dependencies] processing, _ in
            guard let dependencies else { return }
            _ = await dependencies.refreshBrowseProjection(processing: processing)
        }
        await dependencies.refreshArtistCatalog()

        await catalog.replaceTracks([
            catalogTrack(id: "NEW", title: "New Song", artist: "New Artist", album: "New Album"),
        ])
        try await enqueueProjectionRefresh(in: store)

        await dependencies.mirrorEffectDrain?.drain()

        #expect(await catalog.loadCount() == 1)
        #expect(dependencies.catalogSnapshot?.tracks.map(\.title) == ["Old Song"])
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

    @Test("mirror projection refresh clears the active plan without deleting its history")
    func mirrorRefreshClearsActivePlan() async throws {
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })
        let plan = try #require(try makeStoredFixPlan(configuration: dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 1_800_000_100),
            hasDiscogsAccess: true
        )))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let planStore = StoredFixPlanStore(plan: plan, decision: decision)
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            runRecordStore: RunRecordStoreStub(),
            fixPlanStore: planStore,
            cache: cache
        )
        _ = await dependencies.refreshFixPlanProjection()
        #expect(await dependencies.projectionStore.fixPlanProjection().status == .ready)
        try await enqueueProjectionRefresh(in: store)

        await dependencies.mirrorEffectDrain?.drain()

        #expect(await dependencies.projectionStore.fixPlanProjection().status == .empty)
        #expect(try await planStore.latestPlan() == plan)
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

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
        fixture.dependencies.applyBrowseTruth = { processing, token in
            browseApplications.append((
                processing.tracks.count,
                token.map(fixture.dependencies.libraryLoadGate.isCurrent) ?? true
            ))
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

    @Test("Presentation load preserves incomplete readiness")
    func preservesIncompleteReadiness() async throws {
        try await expectPreservedReadiness(.incomplete)
    }

    @Test("Presentation load preserves stale readiness")
    func preservesStaleReadiness() async throws {
        try await expectPreservedReadiness(.stale)
    }

    @Test("Presentation load preserves unavailable readiness")
    func preservesUnavailableReadiness() async throws {
        try await expectPreservedReadiness(.unavailable)
    }

    private func expectPreservedReadiness(_ evidence: NonReadyEvidence) async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let analytics = try await installAnalytics(on: fixture.dependencies)
        let track = canonicalMirrorTrack(Core.Track(
            id: "typed",
            name: "Song",
            artist: "In Flames",
            album: "Foregone"
        ))
        let store: MirrorTrackStoreStub
        let expected: MirrorReadiness
        let expectedSubtitle: String

        switch evidence {
        case .incomplete:
            store = MirrorTrackStoreStub(tracks: [track])
            expected = .incomplete(.freshObservationRequired)
            expectedSubtitle = "Refresh Music metadata before updating"
        case .stale:
            store = MirrorTrackStoreStub(
                tracks: [track],
                certifiedArtists: [],
                certificateObservedAt: .distantPast
            )
            expected = .stale(.metadataExpired)
            expectedSubtitle = "Music metadata expired · refresh before updating"
        case .unavailable:
            store = MirrorTrackStoreStub(
                tracks: [track],
                certifiedArtists: [],
                certificateObservedAt: Date(timeIntervalSince1970: .nan)
            )
            expected = .unavailable(MirrorFailure(
                category: .storage,
                detail: "Mirror observation age must be finite"
            ))
            expectedSubtitle = "Library readiness unavailable: Mirror observation age must be finite"
        }
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        await fixture.dependencies.loadLibrary(forceRefresh: true)

        #expect(fixture.dependencies.libraryReadiness == expected)
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["typed"])
        let projection = await fixture.dependencies.projectionStore.activityProjection()
        #expect(projection.healthFacts.counts.totalTracks == 1)
        #expect(projection.subtitle == expectedSubtitle)
        let row = try #require(await analytics.projection(for: .currentSession).operations.first {
            $0.operationValue == AnalyticsOperation.libraryLoad.rawValue
        })
        #expect(row.succeeded == 0)
        #expect(row.degraded == 1)
        #expect(row.failed == 0)
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
        fixture.dependencies.applyBrowseTruth = { _, _ in
            fixture.dependencies.invalidateLibraryLoads()
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

    @Test("a superseding load prevents stale failure callbacks")
    func dropsStaleFailureCallbacks() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let currentTrack = canonicalMirrorTrack(Core.Track(
            id: "current",
            name: "Current",
            artist: "Clutch",
            album: "Blast Tyrant"
        ))
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(beforeLoad: {
                throw MusicLibraryError.fetchFailed(detail: "stale mirror failure")
            }),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )

        var shouldSupersedeFailure = true
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            guard processing.tracks.isEmpty, shouldSupersedeFailure else { return }
            shouldSupersedeFailure = false
            fixture.dependencies.invalidateLibraryLoads()
            fixture.dependencies.configureLibraryPersistenceForTesting(
                trackStore: MirrorTrackStoreStub(tracks: [currentTrack]),
                librarySnapshotService: fixture.snapshotService,
                runRecordStore: RunRecordStoreStub()
            )
            await fixture.dependencies.loadLibrary()
        }
        var mirrorFactApplications: [[String]] = []
        fixture.dependencies.onMirrorFactsApplied = { tracks in
            mirrorFactApplications.append(tracks.map(\.id))
        }
        var libraryLoadApplications: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            libraryLoadApplications.append(tracks.map(\.id))
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["current"])
        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(mirrorFactApplications == [["current"]])
        #expect(libraryLoadApplications == [["current"]])
    }

    @Test("an invalidated failure preserves existing facts")
    func invalidatedFailureKeepsFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let retainedTrack = canonicalMirrorTrack(Core.Track(
            id: "retained",
            name: "Retained",
            artist: "Clutch",
            album: "Blast Tyrant"
        ))
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [retainedTrack]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        await fixture.dependencies.loadLibrary()

        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(beforeLoad: {
                throw MusicLibraryError.fetchFailed(detail: "invalidated mirror failure")
            }),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            if processing.tracks.isEmpty {
                fixture.dependencies.invalidateLibraryLoads()
            }
        }
        var mirrorFactApplications = 0
        fixture.dependencies.onMirrorFactsApplied = { _ in mirrorFactApplications += 1 }
        var libraryLoadApplications = 0
        fixture.dependencies.onLibraryLoadApplied = { _ in libraryLoadApplications += 1 }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["retained"])
        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(mirrorFactApplications == 0)
        #expect(libraryLoadApplications == 0)
    }

    @Test("a superseding load during analytics drops stale failure facts")
    func dropsPostAnalyticsFailure() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let analyticsStore = BlockingAnalyticsStore()
        var analyticsConfiguration = AnalyticsConfig()
        analyticsConfiguration.enabled = true
        let analytics = AnalyticsRecorder(
            eventStore: analyticsStore,
            configuration: analyticsConfiguration,
            sessionID: UUID()
        )
        await analytics.initialize()
        fixture.dependencies.installTestAnalyticsRecorder(analytics)
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(beforeLoad: {
                throw MusicLibraryError.fetchFailed(detail: "stale analytics failure")
            }),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var browseApplications: [[String]] = []
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            browseApplications.append(processing.tracks.map(\.id))
        }
        var mirrorFactApplications: [[String]] = []
        fixture.dependencies.onMirrorFactsApplied = { tracks in
            mirrorFactApplications.append(tracks.map(\.id))
        }
        var libraryLoadApplications: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            libraryLoadApplications.append(tracks.map(\.id))
        }

        let staleLoad = Task { await fixture.dependencies.loadLibrary() }
        await analyticsStore.waitUntilAppendStarts()
        fixture.dependencies.invalidateLibraryLoads()
        let currentTrack = canonicalMirrorTrack(Core.Track(
            id: "current",
            name: "Current",
            artist: "Clutch",
            album: "Blast Tyrant"
        ))
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: [currentTrack]),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        await fixture.dependencies.loadLibrary()
        await analyticsStore.releaseAppend()
        await staleLoad.value

        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["current"])
        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(browseApplications == [["current"]])
        #expect(mirrorFactApplications == [["current"]])
        #expect(libraryLoadApplications == [["current"]])
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
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            browsedTrackIDs.append(processing.tracks.map(\.id))
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

private actor BlockingAnalyticsStore: AnalyticsEventStore {
    private var shouldBlockNextAppend = true
    private var appendContinuation: CheckedContinuation<Void, Never>?
    private var appendStartedContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedAppend = false

    func append(_: StoredAnalyticsEvent, retention _: AnalyticsRetentionPolicy) async {
        guard shouldBlockNextAppend else { return }
        shouldBlockNextAppend = false
        hasStartedAppend = true
        appendStartedContinuation?.resume()
        appendStartedContinuation = nil
        await withCheckedContinuation { appendContinuation = $0 }
    }

    func events(since _: Date?, sessionID _: UUID?) -> [StoredAnalyticsEvent] {
        []
    }

    func migrateLegacyAnalytics(retention _: AnalyticsRetentionPolicy) {
        // Intentionally empty: this in-memory test store has no legacy analytics state to migrate.
    }

    func waitUntilAppendStarts() async {
        if hasStartedAppend {
            return
        }
        await withCheckedContinuation { appendStartedContinuation = $0 }
    }

    func releaseAppend() {
        appendContinuation?.resume()
        appendContinuation = nil
    }
}
