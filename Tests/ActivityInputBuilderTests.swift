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

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
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
