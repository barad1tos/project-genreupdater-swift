import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

enum ReadinessSample: CaseIterable, CustomTestStringConvertible, Sendable {
    case membership
    case expiredMetadata
    case superseded
    case freshObservation
    case identity
    case metadata
    case narrowed
    case storage

    var testDescription: String {
        switch self {
        case .membership: "membership"
        case .expiredMetadata: "expired metadata"
        case .superseded: "superseded"
        case .freshObservation: "fresh observation"
        case .identity: "identity"
        case .metadata: "metadata"
        case .narrowed: "narrowed"
        case .storage: "storage"
        }
    }

    var readiness: MirrorReadiness {
        switch self {
        case .membership: .stale(.membershipChanged)
        case .expiredMetadata: .stale(.metadataExpired)
        case .superseded: .stale(.supersededRevision)
        case .freshObservation: .incomplete(.freshObservationRequired)
        case .identity: .incomplete(.identityMissing(count: 2))
        case .metadata: .incomplete(.metadataMissing(count: 3))
        case .narrowed: .incomplete(.narrowedObservation)
        case .storage:
            .unavailable(MirrorFailure(category: .storage, detail: "Certificate checksum is invalid"))
        }
    }

    var detail: String {
        switch self {
        case .membership: "Music library changed · refresh before updating"
        case .expiredMetadata: "Music metadata expired · refresh before updating"
        case .superseded: "Library mirror changed · reload before updating"
        case .freshObservation: "Refresh Music metadata before updating"
        case .identity: "2 tracks need identity repair before updating"
        case .metadata: "3 tracks need metadata refresh before updating"
        case .narrowed: "Run a full scope refresh before updating"
        case .storage: "Library readiness unavailable: Certificate checksum is invalid"
        }
    }

    var buttonTitle: String {
        switch self {
        case .membership, .expiredMetadata, .freshObservation, .metadata, .narrowed:
            "Refresh Required"
        case .superseded:
            "Reload Required"
        case .identity:
            "Repair Required"
        case .storage:
            "Library Unavailable"
        }
    }
}

@Suite("ActivityInputBuilder")
struct ActivityInputBuilderTests {
    @Test("mirror effect failure stays operational instead of replacing the app")
    @MainActor
    func surfacesMirrorEffectFailureWithoutFatalState() async throws {
        let fixture = try makeFixture(testArtists: [])
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(trackStore: store, cache: cache)
        let mirror = try await store.loadMirrorSnapshot()
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: mirror.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.invalidateSnapshot]
        ))

        let drain = try #require(fixture.dependencies.mirrorEffectDrain)
        await drain.drain()
        let projection = await fixture.dependencies.projectionStore.activityProjection()

        #expect(fixture.dependencies.mirrorEffectDrainIssue?.id == "mirror-effect-drain")
        #expect(projection.operationalIssues.contains { $0.id == "mirror-effect-drain" })
        if case .error = fixture.dependencies.appState {
            Issue.record("A post-commit effect failure must not replace committed mirror truth")
        }

        let snapshot = SnapshotServiceSpy()
        let projections = try #require(fixture.dependencies.mirrorProjectionOutput)
        await drain.updateTargets(cache: cache, snapshot: snapshot, projections: projections)
        await drain.drain()

        #expect(fixture.dependencies.mirrorEffectDrainIssue == nil)
        let recoveredProjection = await fixture.dependencies.projectionStore.activityProjection()
        #expect(!recoveredProjection.operationalIssues.contains { $0.id == "mirror-effect-drain" })
    }

    @Test("startup persistence wiring automatically replays pending projection effects")
    @MainActor
    func startupPersistenceWiringReplaysPendingEffects() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let seedStore = TrackDataStore(modelContainer: container)
        try await seedStore.initialize()
        let initial = try await seedStore.loadMirrorSnapshot()
        _ = try await seedStore.commitMirror(MirrorCommit(
            baseRevision: initial.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.refreshProjections]
        ))
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Intentionally empty: this projection test never persists configuration.
            },
            modelContainerFactory: { container }
        )
        _ = await dependencies.projectionStore.replaceFixPlanProjection(
            .unavailable(message: "stale fixture")
        )
        _ = await dependencies.projectionStore.replaceReportsProjection(ReportsProjection(
            revision: .initial,
            runs: [],
            skippedCorruptedCount: 1
        ))

        try await dependencies.initializePersistence(cacheConfiguration: dependencies.config)

        let installedStore = try #require(dependencies.trackStore)
        #expect(try await installedStore.pendingMirrorEffects().isEmpty)
        #expect(await dependencies.projectionStore.fixPlanProjection().status == .empty)
        #expect(await dependencies.projectionStore.reportsProjection().skippedCorruptedCount == 0)
        #expect(await dependencies.projectionStore.activityProjection().revision != .initial)
        #expect(await dependencies.projectionStore.currentChrome().revision != .initial)
    }

    @Test("projection refresh failure retains the durable effect and publishes an issue")
    @MainActor
    func projectionRefreshFailureRetainsEffect() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        )
        let store = fixture.trackStore
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            runRecordStore: RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile)),
            cache: cache
        )
        let initial = try await store.loadMirrorSnapshot()
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: initial.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.refreshProjections]
        ))

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().count == 1)
        #expect(fixture.dependencies.mirrorEffectDrainIssue?.category == .temporaryUnavailable)
        #expect(
            await fixture.dependencies.projectionStore.activityProjection().operationalIssues
                .contains { $0.id == "mirror-effect-drain" }
        )
    }

    @Test("fix plan read failure retains the durable projection effect")
    @MainActor
    func fixPlanReadKeepsEffect() async throws {
        let fixture = try makeFixture(testArtists: [])
        let store = fixture.trackStore
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            runRecordStore: RunRecordStoreStub(),
            fixPlanStore: FailingFixPlanStore(),
            cache: cache
        )
        try await enqueueProjectionRefresh(in: store)

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().count == 1)
        #expect(fixture.dependencies.mirrorEffectDrainIssue?.category == .temporaryUnavailable)
    }

    @Test("activity history read failure retains the durable projection effect")
    @MainActor
    func historyReadKeepsEffect() async throws {
        let fixture = try makeFixture(testArtists: [])
        let store = fixture.trackStore
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            runRecordStore: RunRecordStoreStub(),
            cache: cache
        )
        fixture.dependencies.installTestChangeLogStore(FailingChangeLogStore())
        try await enqueueProjectionRefresh(in: store)

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().count == 1)
        #expect(fixture.dependencies.mirrorEffectDrainIssue?.category == .temporaryUnavailable)
    }

    @Test("projection refresh reloads committed mirror membership before publishing activity")
    @MainActor
    func refreshReloadsMirrorMembership() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let store = fixture.trackStore
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub(),
            cache: cache
        )
        let removedTrack = Core.Track(
            id: "removed-track",
            name: "Removed Track",
            artist: "In Flames",
            album: "Foregone",
            appleScriptID: "removed-track"
        )
        let databaseID = try #require(removedTrack.databaseID)
        let initial = try await store.loadMirrorSnapshot()
        let seedInventory = try InventoryChange.replace(
            stamp: testMembershipStamp(for: [databaseID]),
            ids: [databaseID],
            identities: testIdentities(for: [removedTrack]),
            observedAt: .distantPast
        )
        let seeded = try await store.commitMirror(MirrorCommit(
            baseRevision: initial.revision,
            inventoryChange: seedInventory,
            repairs: [],
            upserts: [removedTrack],
            certificates: .invalidate(.membershipChanged)
        ))
        fixture.dependencies.libraryTracks = [removedTrack]
        let emptyInventory = try InventoryChange.replace(
            stamp: testMembershipStamp(for: []),
            ids: [],
            identities: [],
            observedAt: .now
        )
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: seeded.revision,
            inventoryChange: emptyInventory,
            repairs: [],
            upserts: [],
            certificates: .invalidate(.membershipChanged),
            effects: [.refreshProjections]
        ))

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }

    @Test("projection refresh retry preserves library-load bookkeeping")
    @MainActor
    func projectionRefreshRetryPreservesLoadBookkeeping() async throws {
        let setup = try await makeProjectionRetrySetup()
        let fixture = setup.fixture
        let store = fixture.trackStore
        let persistedMetrics = setup.persistedMetrics
        let incrementalBaseline = track(id: "incremental-baseline")
        let expectedMirrorMetrics = expectedMirrorMetrics(preserving: persistedMetrics)
        var browsedTrackIDs: [[String]] = []
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            browsedTrackIDs.append(processing.tracks.map(\.id))
        }
        var mirrorFactTrackIDs: [[String]] = []
        fixture.dependencies.onMirrorFactsApplied = { tracks in
            mirrorFactTrackIDs.append(tracks.map(\.id))
        }
        var libraryLoadTrackIDs: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            libraryLoadTrackIDs.append(tracks.map(\.id))
        }
        fixture.dependencies.replacePreviousIncrementalScopeTracks([incrementalBaseline])
        fixture.dependencies.libraryMetrics = persistedMetrics
        fixture.dependencies.libraryTracks = [canonicalMirrorTrack(track(id: "stale-presentation"))]
        try await store.seedMirror([track(id: "committed-mirror")])
        try await enqueueProjectionRefresh(in: store)

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().count == 1)
        #expect(fixture.dependencies.previousIncrementalScopeTracks == [incrementalBaseline])
        #expect(await setup.metricsStore.loadLatest() == persistedMetrics)
        #expect(await setup.analytics.projection(for: .currentSession).summary.calls == 0)
        #expect(fixture.dependencies.libraryReadiness.isReady)
        #expect(fixture.dependencies.libraryMetrics == expectedMirrorMetrics)
        #expect(browsedTrackIDs.last == ["committed-mirror"])
        #expect(mirrorFactTrackIDs == [["committed-mirror"]])
        #expect(libraryLoadTrackIDs.isEmpty)

        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            librarySnapshotService: fixture.snapshotService,
            metricsSnapshotStore: setup.metricsStore,
            runRecordStore: RunRecordStoreStub(),
            cache: setup.cache
        )
        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().isEmpty)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["committed-mirror"])
        #expect(fixture.dependencies.previousIncrementalScopeTracks == [incrementalBaseline])
        #expect(await setup.metricsStore.loadLatest() == persistedMetrics)
        #expect(await setup.analytics.projection(for: .currentSession).summary.calls == 0)
        #expect(fixture.dependencies.libraryReadiness.isReady)
        #expect(fixture.dependencies.libraryMetrics == expectedMirrorMetrics)
        #expect(browsedTrackIDs.last == ["committed-mirror"])
        #expect(mirrorFactTrackIDs == [["committed-mirror"], ["committed-mirror"]])
        #expect(libraryLoadTrackIDs.isEmpty)
        #expect(fixture.dependencies.mirrorEffectDrainIssue == nil)
    }

    @Test("cancelled projection refresh does not partially apply mirror facts")
    @MainActor
    func cancelledProjectionRefreshPreservesPreviousFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let store = fixture.trackStore
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub(),
            cache: cache
        )
        let previousTrack = canonicalMirrorTrack(track(id: "previous-presentation"))
        let previousReadiness = MirrorReadiness.incomplete(.freshObservationRequired)
        fixture.dependencies.libraryTracks = [previousTrack]
        fixture.dependencies.libraryReadiness = previousReadiness
        try await store.seedMirror([track(id: "committed-mirror")])
        try await enqueueProjectionRefresh(in: store)
        fixture.dependencies.applyBrowseTruth = { _, _ in
            fixture.dependencies.invalidateLibraryLoads()
        }

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().count == 1)
        #expect(fixture.dependencies.libraryTracks == [previousTrack])
        #expect(fixture.dependencies.libraryReadiness == previousReadiness)
    }

    @Test("projection refresh without prior metrics does not invent a scan date")
    @MainActor
    func projectionRefreshWithoutMetricsKeepsMetricsAbsent() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let store = fixture.trackStore
        try await store.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub(),
            cache: cache
        )
        try await store.seedMirror([track(id: "committed-mirror")])
        try await enqueueProjectionRefresh(in: store)

        await fixture.dependencies.mirrorEffectDrain?.drain()

        #expect(try await store.pendingMirrorEffects().isEmpty)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["committed-mirror"])
        #expect(fixture.dependencies.libraryMetrics == nil)
    }

    @Test("corrupted mirror queue asks for repair instead of retry")
    @MainActor
    func corruptedMirrorQueueHasRepairIssue() async throws {
        let fixture = try makeFixture(testArtists: [])
        let reporter = AppMirrorEffectReporter(dependencies: fixture.dependencies)

        await reporter.reportMirrorEffectFailure(MirrorEffectDrainFailure(
            kind: .corruptedQueue,
            detail: "Malformed persisted effect"
        ))

        #expect(fixture.dependencies.mirrorEffectDrainIssue?.category == .internalFailure)
        #expect(fixture.dependencies.mirrorEffectDrainIssue?.nextAction?.contains("repair") == true)
    }

    @Test("permission denied load error maps to permissionDenied library state")
    func mapsPermissionDenied() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: .permissionDenied,
            isLoading: false
        ))

        #expect(input.libraryState == .permissionDenied(LibraryLoadError.permissionDenied.message))
    }

    @Test("failed load error maps to failed library state")
    func mapsFailedLoad() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: .failed("Music.app is unavailable"),
            isLoading: false
        ))

        #expect(input.libraryState == .failed("Music.app is unavailable"))
    }

    @Test("loading with no error maps to loading library state")
    func mapsLoadingState() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            loadError: nil,
            isLoading: true
        ))

        #expect(input.libraryState == .loading)
    }

    @Test("no error and not loading maps to empty or ready by track count")
    func mapsTrackCountState() throws {
        let emptyInput = try ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [],
            loadError: nil,
            isLoading: false,
            readiness: makeReadyEvidence()
        ))
        let readyInput = try ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false,
            readiness: makeReadyEvidence()
        ))

        #expect(emptyInput.libraryState == .empty)
        #expect(readyInput.libraryState == .ready)
    }

    @Test("Every non-ready reason keeps actionable presentation behavior", arguments: ReadinessSample.allCases)
    func projectsNonReady(sample: ReadinessSample) throws {
        let copy = try #require(LibraryReadinessCopy(sample.readiness))
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false,
            readiness: sample.readiness
        ))
        let projection = ActivityBuilder.makeProjection(from: input)
        let detectStage = try #require(projection.stageDescriptors.first { $0.stage == .detect })
        let scan = try #require(projection.recentActivity.first { $0.id == "scan" })

        #expect(copy.detail == sample.detail)
        #expect(copy.buttonTitle == sample.buttonTitle)
        #expect(input.libraryState == .presentationOnly(sample.detail))
        #expect(projection.title == "Library needs refresh")
        #expect(projection.subtitle == sample.detail)
        #expect(projection.currentStage == .detect)
        #expect(detectStage.status == .current)
        #expect(scan.title == "Library scan")
        #expect(scan.detail == sample.detail)
        #expect(projection.operationalIssues.isEmpty)
        #expect(projection.summaryCards.map(\.id) == ["automation", "delta", "quality"])
    }

    @Test("Empty presentation preserves every non-ready reason", arguments: ReadinessSample.allCases)
    func keepsEmptyReason(sample: ReadinessSample) {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [],
            loadError: nil,
            isLoading: false,
            readiness: sample.readiness
        ))

        #expect(input.libraryState == .presentationOnly(sample.detail))
    }

    @Test("Only a ready empty presentation maps to empty")
    func mapsReadyEmpty() throws {
        let input = try ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [],
            loadError: nil,
            isLoading: false,
            readiness: makeReadyEvidence()
        ))

        #expect(input.libraryState == .empty)
    }

    @Test("fix plan projection maps to activity summary")
    func mapsFixPlanProjection() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false,
            fixPlanProjection: fixPlanProjection()
        ))

        #expect(input.fixPlan == ActivityFixPlanSummary(
            status: .ready,
            itemCount: 4,
            acceptedCount: 3,
            canApply: true
        ))
        #expect(input.proposedFixCount == 4)
        #expect(input.acceptedFixCount == 3)
    }

    @Test("recovery report rows map to activity summary")
    func mapsRecoveryRows() {
        let input = ActivityInputBuilder.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false,
            reportsProjection: ReportsProjection(
                revision: .initial,
                runs: [
                    ReportsRunItem(
                        id: "run-blocked",
                        state: .blocked,
                        stateLabel: "Blocked",
                        triggerLabel: "Manual check",
                        startedLabel: "4m ago",
                        modeLabel: "Library check",
                        scopeLabel: "Full library",
                        durationLabel: nil,
                        changeCountLabel: nil,
                        failureSummary: "Run blocked"
                    ),
                    ReportsRunItem(
                        id: "run-recovery",
                        state: .recoveryNeeded,
                        stateLabel: "Recovery needed",
                        triggerLabel: "Manual check",
                        startedLabel: "8m ago",
                        modeLabel: "Library check",
                        scopeLabel: "Full library",
                        durationLabel: nil,
                        changeCountLabel: nil,
                        failureSummary: "Previous run needs recovery"
                    ),
                    ReportsRunItem(
                        id: "run-failed",
                        state: .failed,
                        stateLabel: "Failed",
                        triggerLabel: "Manual check",
                        startedLabel: "12m ago",
                        modeLabel: "Library check",
                        scopeLabel: "Full library",
                        durationLabel: nil,
                        changeCountLabel: nil,
                        failureSummary: "Run failed"
                    ),
                ],
                skippedCorruptedCount: 0,
                recoveryRunIDs: ["run-blocked", "run-recovery"]
            )
        ))

        #expect(input.recovery == ActivityRecoverySummary(
            unresolvedRunCount: 2,
            latestRecoveryRunID: "run-blocked"
        ))
    }

    private struct ProjectionRetrySetup {
        let fixture: LibraryPersistenceFixture
        let cache: GRDBCacheService
        let metricsStore: MetricsSnapshotStore
        let persistedMetrics: MetricsSnapshotValues
        let analytics: AnalyticsRecorder
    }

    @MainActor
    private func makeProjectionRetrySetup() async throws -> ProjectionRetrySetup {
        let failingReports = RunRecordStoreStub(reportsError: CocoaError(.fileReadCorruptFile))
        let fixture = try makeFixture(testArtists: [], runRecordStore: failingReports)
        try await fixture.trackStore.initialize()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let metricsStore = try MetricsSnapshotStore(modelContainer: ModelContainerFactory.createInMemory())
        await metricsStore.upsert(from: [track(id: "metrics-before")])
        await metricsStore.upsert(from: [track(id: "metrics-current"), track(id: "metrics-current-2")])
        let persistedMetrics = try #require(await metricsStore.loadLatest())
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: fixture.trackStore,
            librarySnapshotService: fixture.snapshotService,
            metricsSnapshotStore: metricsStore,
            runRecordStore: failingReports,
            cache: cache
        )
        var analyticsConfiguration = AnalyticsConfig()
        analyticsConfiguration.enabled = true
        let analytics = AnalyticsRecorder(store: cache, configuration: analyticsConfiguration)
        await analytics.initialize()
        fixture.dependencies.installTestAnalyticsRecorder(analytics)
        return ProjectionRetrySetup(
            fixture: fixture,
            cache: cache,
            metricsStore: metricsStore,
            persistedMetrics: persistedMetrics,
            analytics: analytics
        )
    }

    private func expectedMirrorMetrics(preserving previous: MetricsSnapshotValues) -> MetricsSnapshotValues {
        MetricsSnapshotValues(
            totalTracks: 1,
            tracksWithGenre: 0,
            tracksWithYear: 0,
            tracksWithBoth: 0,
            tracksNeedingGenre: 1,
            tracksNeedingYear: 1,
            recentlyAdded: 0,
            timestamp: previous.timestamp,
            previousTotalTracks: previous.previousTotalTracks,
            previousTracksNeedingGenre: previous.previousTracksNeedingGenre,
            previousTracksNeedingYear: previous.previousTracksNeedingYear,
            previousRecentlyAdded: previous.previousRecentlyAdded
        )
    }

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
    }

    private func enqueueProjectionRefresh(in store: any TrackStateStore) async throws {
        let initial = try await store.loadMirrorSnapshot()
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: initial.revision,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve,
            effects: [.refreshProjections]
        ))
    }

    private func makeContext(
        tracks: [Core.Track] = [],
        loadError: LibraryLoadError?,
        isLoading: Bool,
        readiness: MirrorReadiness = .incomplete(.freshObservationRequired),
        fixPlanProjection: FixPlanProjection = .empty(),
        reportsProjection: ReportsProjection = .empty()
    ) -> ActivityInputContext {
        ActivityInputContext(
            tracks: tracks,
            reportEntries: [],
            metricsSnapshot: nil,
            lastScanDate: nil,
            loadError: loadError,
            isLoading: isLoading,
            readiness: readiness,
            isDryRun: false,
            workflow: .empty,
            fixPlanProjection: fixPlanProjection,
            reportsProjection: reportsProjection,
            queuedWrite: nil,
            pendingVerification: nil,
            mirrorEffectIssue: nil,
            runLifecycle: nil,
            isLibrarySyncAvailable: true,
            isAutomationArmed: false,
            now: Date(timeIntervalSince1970: 100)
        )
    }

    private func fixPlanProjection() -> FixPlanProjection {
        FixPlanProjection(
            revision: .initial,
            status: .ready,
            lineage: FixPlanProjection.Lineage(
                planID: nil,
                planRevision: nil,
                decisionRevision: nil,
                sourceRunID: nil
            ),
            scope: nil,
            summary: FixPlanProjection.Summary(
                itemCount: 4,
                acceptedCount: 3,
                rejectedCount: 1,
                genreCount: 3,
                yearCount: 1,
                trackCleaningCount: 0,
                albumCleaningCount: 0,
                artistRenameCount: 0,
                affectedTrackCount: 0,
                affectedAlbumCount: 0,
                averageConfidence: 92,
                canApply: true
            ),
            stalenessReasons: [],
            items: [],
            operationalIssues: []
        )
    }
}

private actor FailingFixPlanStore: FixPlanStore {
    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {
        // Intentionally empty: this double fails reads, while writes are irrelevant.
    }

    func plan(id _: FixPlanID, revision _: FixPlanRevision) async throws -> FixPlan? {
        nil
    }

    func latestPlan() async throws -> FixPlan? {
        throw CocoaError(.fileReadCorruptFile)
    }

    func currentDecision(for _: FixPlanID) async throws -> FixPlanReviewDecision? {
        nil
    }

    func recordDecision(_: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        throw CocoaError(.fileWriteUnknown)
    }

    func deletePlans(notIn _: Set<FixPlanID>) async throws -> Int {
        0
    }
}

private actor FailingChangeLogStore: ChangeLogStore {
    func saveEntries(_: [ChangeLogEntry]) async throws {
        // Intentionally empty: this double fails reads, while writes are irrelevant.
    }

    func loadAll() async throws -> [ChangeLogEntry] {
        throw CocoaError(.fileReadCorruptFile)
    }

    func loadRecent(limit _: Int) async throws -> [ChangeLogEntry] {
        throw CocoaError(.fileReadCorruptFile)
    }

    func delete(entryID _: UUID) async throws {
        // Intentionally empty: deletion is outside the activity read-failure scenario.
    }

    func deleteAll() async throws {
        // Intentionally empty: deletion is outside the activity read-failure scenario.
    }
}
