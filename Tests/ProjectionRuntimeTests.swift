import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Projection runtime")
@MainActor
struct ProjectionRuntimeTests {
    private func makeDependencies() -> AppDependencies {
        AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these pins.
            }
        )
    }

    private func makeLibraryFacts(tracks: [Core.Track]) -> ActivityLibraryFacts {
        ActivityLibraryFacts(
            tracks: tracks,
            metricsSnapshot: nil,
            lastScanDate: Date(timeIntervalSince1970: 100),
            loadError: nil,
            isLoading: false
        )
    }

    @Test("backend activity refresh publishes host-supplied facts")
    func activityRefreshPublishes() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")

        let published = await dependencies.refreshActivityProjection(
            library: makeLibraryFacts(tracks: [track]),
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil),
            runLifecycle: nil
        )

        // A non-empty ready library differs from the empty sentinel's
        // sync text, proving the publish carried the supplied facts.
        #expect(published.revision != .initial)
        #expect(await dependencies.projectionStore.activityProjection() == published)
    }

    @Test("reports refresh publishes with no host state at all")
    func reportsRefreshHeadless() async throws {
        // The unified path reads the active run from the orchestrator,
        // never from view state — usable from any window-independent
        // caller.
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())

        let published = await fixture.dependencies.refreshReportsProjection()

        #expect(published != nil)
        #expect(await fixture.dependencies.projectionStore.reportsProjection() == published)
    }

    @Test("a lifecycle boundary publishes projections with no window")
    func lifecycleBoundaryPublishesHeadless() async {
        let dependencies = makeDependencies()
        let lifecycle = makeLifecycle(phase: .active(.syncingLibrary))

        await dependencies.publishLifecycleBoundary(lifecycle)

        #expect(dependencies.currentLifecycleSnapshot == lifecycle)
        #expect(await dependencies.projectionStore.activityProjection().revision != .initial)
        #expect(await dependencies.projectionStore.currentChrome().syncStatus.isRunActive)
    }

    @Test("per-item checkpoints do not re-derive chrome")
    func chromeThrottleAtRunStateBoundary() async {
        let dependencies = makeDependencies()
        let lifecycle = makeLifecycle(phase: .active(.writing))

        await dependencies.publishLifecycleBoundary(lifecycle)
        let afterFirst = await dependencies.projectionStore.currentChrome().revision
        // The same (run, state) again — a per-item write checkpoint.
        await dependencies.publishLifecycleBoundary(lifecycle)
        let afterSecond = await dependencies.projectionStore.currentChrome().revision

        #expect(afterSecond == afterFirst)
    }

    @Test("a terminal boundary republishes reports")
    func terminalBoundaryRepublishesReports() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(
                reportPage: RunReportPage(records: [sampleRunRecord()], skippedCorruptedCount: 0)
            )
        )
        let baseline = await fixture.dependencies.projectionStore.reportsProjection().revision

        await fixture.dependencies.publishLifecycleBoundary(
            makeLifecycle(phase: .finished(.completed(SyncResult()), finishedAt: Date(timeIntervalSince1970: 200)))
        )

        let after = await fixture.dependencies.projectionStore.reportsProjection().revision
        #expect(after != baseline)
    }

    private func makeLifecycle(phase: RunPhase) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: startedAt,
                reason: "runtime-test"
            ),
            startedAt: startedAt,
            phase: phase
        )
    }

    @Test("an aborted browse refresh publishes nothing")
    func abortedBrowseRefreshPublishesNothing() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")

        let result = await dependencies.refreshBrowseProjection(
            tracks: [track],
            readSource: .cachedMirror(scannedAt: nil),
            isCurrent: { false }
        )

        #expect(result == nil)
        #expect(await dependencies.projectionStore.currentBrowse().artists.isEmpty)
    }

    @Test("a landed browse refresh pairs rows with its own projection")
    func landedBrowseRefreshPairsRows() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")

        let result = await dependencies.refreshBrowseProjection(
            tracks: [track],
            readSource: .cachedMirror(scannedAt: nil)
        )

        #expect(result?.projection.artists.count == 1)
        #expect(result?.rowIndex?.count == 1)
    }

    @Test("no direct store publish remains in the host view")
    func hostViewPublishesNothing() throws {
        // Source-scan pin (house precedent): subscriptions are the only
        // store surface a view may touch (ADR 0013).
        let source = try String(contentsOf: hostViewSourceURL(), encoding: .utf8)

        for forbidden in [
            "replaceActivityProjection", "replaceReportsProjection",
            "replaceFixPlanProjection", "replaceSettingsProjection",
            "replaceChromeProjection", "replaceBrowseProjection",
            "InputGeneration()", "Builder.makeProjection",
        ] {
            #expect(!source.contains(forbidden), "host view must not touch \(forbidden)")
        }
    }

    private func hostViewSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Views/DesignRootHostView.swift")
    }

    @Test("identical activity facts keep the revision")
    func activityRefreshDedups() async {
        let dependencies = makeDependencies()
        let facts = makeLibraryFacts(tracks: [])

        let first = await dependencies.refreshActivityProjection(
            library: facts,
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil),
            runLifecycle: nil
        )
        let second = await dependencies.refreshActivityProjection(
            library: facts,
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil),
            runLifecycle: nil
        )

        #expect(second.revision == first.revision)
    }
}
