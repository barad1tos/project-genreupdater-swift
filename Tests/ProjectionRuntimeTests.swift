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

    private func installCatalog(_ tracks: [Core.Track], on dependencies: AppDependencies) {
        dependencies.catalogSnapshot = CatalogSnapshot(tracks: tracks.map { track in
            guard let id = CatalogTrackID(displayValue: track.id) else {
                preconditionFailure("Projection runtime fixture catalog IDs must be non-empty")
            }
            return CatalogTrack(
                id: id,
                title: track.name,
                artist: track.artist,
                album: track.album,
                albumArtist: track.albumArtist,
                genres: track.genre.map { [$0] } ?? [],
                dates: CatalogDates(releaseYear: track.year, dateAdded: track.dateAdded)
            )
        })
        dependencies.catalogSnapshotSource = .live
    }

    private func makeProcessingFacts(_ tracks: [Core.Track]) -> BrowseProcessingFacts {
        BrowseProcessingFacts(tracks: tracks, readiness: .incomplete(.freshObservationRequired))
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
        installCatalog([track], on: dependencies)

        let published = await dependencies.refreshActivityProjection(
            library: makeLibraryFacts(tracks: [track]),
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
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

    @Test("a terminal boundary advances the queued reload without a window")
    func terminalBoundaryAdvancesQueuedReloadHeadlessly() async throws {
        // The observer outlives any window (D4): a menu-queued reload
        // must advance even when no host view is subscribed.
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(
                tracks: [
                    canonicalMirrorTrack(Core.Track(
                        id: "live",
                        name: "Song",
                        artist: "Clutch",
                        album: "Blast Tyrant"
                    )),
                ],
                certifiedArtists: []
            ),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        fixture.dependencies.queuedManualReload = .waitingForQueued

        await fixture.dependencies.publishLifecycleBoundary(
            makeLifecycle(phase: .finished(.completed(SyncResult()), finishedAt: Date(timeIntervalSince1970: 200)))
        )

        #expect(fixture.dependencies.queuedManualReload == nil)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["live"])
    }

    private func makeLifecycle(phase: RunPhase, intent: RunIntent = .observeLibrary) -> RunLifecycleSnapshot {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: intent,
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
        installCatalog([track], on: dependencies)

        let result = await dependencies.refreshBrowseProjection(
            processing: makeProcessingFacts([track]),
            isCurrent: { false }
        )

        #expect(result == nil)
        #expect(await dependencies.projectionStore.currentBrowse().artists.isEmpty)
    }

    @Test("a landed browse refresh pairs rows with its own projection")
    func landedBrowseRefreshPairsRows() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")
        installCatalog([track], on: dependencies)

        let result = await dependencies.refreshBrowseProjection(processing: makeProcessingFacts([track]))

        #expect(result?.projection.artists.count == 1)
        #expect(result?.rowIndex?.count == 1)
    }

    @Test("no direct store publish remains in any view")
    func viewsPublishNothing() throws {
        // Source-scan pin (house precedent): subscriptions are the only
        // store surface a view may touch (ADR 0013). Every file under
        // App/Views is scanned so a helper cannot smuggle a publish in.
        let viewsDirectory = try libraryLoadSourceURL().deletingLastPathComponent()
        let sources = try swiftSources(under: viewsDirectory)
        #expect(!sources.isEmpty)

        for fileURL in sources {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for forbidden in [
                "replaceActivityProjection", "replaceReportsProjection",
                "replaceFixPlanProjection", "replaceSettingsProjection",
                "replaceChromeProjection", "replaceBrowseProjection",
                "InputGeneration()", "Builder.makeProjection",
                "publishBrowseProjection(",
                "FetchDescriptor<", "modelContext.fetch",
            ] {
                #expect(
                    !source.contains(forbidden),
                    "\(fileURL.lastPathComponent) must not touch \(forbidden)"
                )
            }
        }
    }

    private func swiftSources(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("the started observer converts a real run into publishes")
    func observerConvertsRunIntoPublishes() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.installTrackCountSource { 1 }
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this observer pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))
        fixture.dependencies.startLifecycleProjectionObserver()
        #expect(fixture.dependencies.lifecycleObserverTask != nil)

        _ = try await fixture.dependencies.submitManualRun()

        // The observer consumes its own buffered stream; poll briefly.
        for _ in 0 ..< 50 {
            if await fixture.dependencies.projectionStore.activityProjection().revision != .initial {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await fixture.dependencies.projectionStore.activityProjection().revision != .initial)
        #expect(fixture.dependencies.currentLifecycleSnapshot != nil)
    }

    @Test("the fact cache survives into observer republishes")
    func factCacheFeedsRepublish() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")

        let refreshed = await dependencies.refreshActivityProjection(
            library: makeLibraryFacts(tracks: [track]),
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        )
        let republished = await dependencies.republishActivityProjection()

        // A dropped cache write would rebuild from empty facts, change
        // the content, and advance the revision.
        #expect(republished == refreshed)
    }

    @Test("a terminal preview boundary refreshes the fix plan")
    func previewTerminalRefreshesFixPlan() async throws {
        let dependencies = makeDependencies()
        let trackStore = try TrackDataStore.createInMemory()
        try await trackStore.initialize()
        let plan = try #require(try makeStoredFixPlan(configuration: dependencies.captureFixPlanConfig(
            at: Date(timeIntervalSince1970: 1_800_000_100),
            hasDiscogsAccess: true
        )))
        let decision = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: trackStore,
            fixPlanStore: StoredFixPlanStore(plan: plan, decision: decision)
        )
        let baseline = await dependencies.projectionStore.fixPlanProjection().revision

        await dependencies.publishLifecycleBoundary(makeLifecycle(
            phase: .finished(.completed(SyncResult()), finishedAt: Date(timeIntervalSince1970: 200)),
            intent: .previewFixes
        ))

        let projection = await dependencies.projectionStore.fixPlanProjection()
        #expect(projection.status == .ready)
        #expect(projection.revision != baseline)
    }

    @Test("chrome falls back to the orchestrator probe before the observer runs")
    func chromeFallbackProbesOrchestrator() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.installTrackCountSource { 1 }
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this probe pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))
        _ = try await fixture.dependencies.submitManualRun()
        #expect(fixture.dependencies.currentLifecycleSnapshot == nil)

        let published = await fixture.dependencies.refreshChromeProjection()

        // The probe found the finished run — a deleted fallback would
        // leave the empty sentinel's Idle line.
        #expect(published.syncStatus.text != "Idle")
    }

    @Test("a terminal boundary publishes activity AFTER reports")
    func terminalBoundaryOrdersActivityAfterReports() async throws {
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(
                reportPage: RunReportPage(
                    records: [sampleRunRecord()],
                    skippedCorruptedCount: 1,
                    corruptedRunIDs: [RunID()],
                    recoveryRunIDs: [RunID()]
                )
            )
        )

        await fixture.dependencies.publishLifecycleBoundary(makeLifecycle(
            phase: .finished(.completed(SyncResult()), finishedAt: Date(timeIntervalSince1970: 200))
        ))

        // Activity embeds reports truth: the recovery summary from the
        // just-refreshed reports must be visible in the SAME boundary's
        // activity publish, headless.
        let activity = await fixture.dependencies.projectionStore.activityProjection()
        #expect(activity.operationalIssues.contains { $0.category == .recoveryRequired })
    }

    @Test("supersession after publish keeps the store but returns nil")
    func supersededAfterPublishKeepsStore() async {
        let dependencies = makeDependencies()
        let track = Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")
        installCatalog([track], on: dependencies)
        let currentFlags = CurrentFlagSequence(values: [true, false])

        let result = await dependencies.refreshBrowseProjection(
            processing: makeProcessingFacts([track]),
            isCurrent: { currentFlags.next() }
        )

        #expect(result == nil)
        #expect(await dependencies.projectionStore.currentBrowse().artists.count == 1)
    }

    @Test("initialize clears the previous session's lifecycle state")
    func initializeClearsLifecycleState() async {
        let dependencies = makeDependencies()
        await dependencies.publishLifecycleBoundary(makeLifecycle(phase: .active(.writing)))
        #expect(dependencies.currentLifecycleSnapshot != nil)

        await dependencies.initialize()

        // Even the bootstrap chrome publishes must read a cleared
        // snapshot on a re-initialize — the dead session's run line
        // must never survive into the new one.
        #expect(dependencies.currentLifecycleSnapshot == nil)
        #expect(dependencies.lastChromeLifecycleRunID == nil)
    }

    @Test("a menu run refusal is the same typed status the surface renders")
    func menuRunRefusalIsTyped() async {
        // No orchestrator installed: the ActivityCommands ladder must
        // answer with the typed temporaryUnavailable, not a silent log.
        let dependencies = makeDependencies()

        let result = await dependencies.makeMenuActivityCommands().handle(.runManually())

        #expect(result.status == .temporaryUnavailable)
        #expect(result.issue?.category == .temporaryUnavailable)
    }

    @Test("the settings projection retains the token reference in memory")
    func settingsProjectionRetainsTokenReference() async {
        // Redaction is an ENCODE-time concern (the FixPlanConfig
        // precedent); applying it to the in-memory projection would
        // silently break every reference-driven display fact.
        let dependencies = makeDependencies()
        dependencies.config.yearRetrieval.apiAuth.discogsTokenReference = "keychain:test"

        _ = await dependencies.publishSettingsProjection()

        let stored = await dependencies.projectionStore.currentSettings()
        #expect(stored.configuration.yearRetrieval.apiAuth.discogsTokenReference == "keychain:test")
    }

    @Test("discogs display state trusts the credential factory, not the reference")
    func discogsStateMapping() {
        typealias State = DesignRootHostView
        // missingToken is the factory's verdict AFTER the resolved
        // reference and the Keychain fallback both came up empty — the
        // only authoritative no-token signal. A nil issue means a token
        // exists somewhere (possibly Keychain-only, invisible to the
        // reference resolver), so it never maps to noToken.
        #expect(State.discogsDisplayState(
            issue: .missingToken, isAccessAvailable: nil
        ) == .noToken)
        #expect(State.discogsDisplayState(
            issue: .other("rejected"), isAccessAvailable: nil
        ) == .tokenIssue)
        #expect(State.discogsDisplayState(
            issue: nil, isAccessAvailable: true
        ) == .connected)
        #expect(State.discogsDisplayState(
            issue: nil, isAccessAvailable: false
        ) == .tokenIssue)
        #expect(State.discogsDisplayState(
            issue: nil, isAccessAvailable: nil
        ) == .unverified)
    }

    @Test("a menu run with an orchestrator reaches submission")
    func menuRunHappyPath() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.installTrackCountSource { 1 }
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))

        let result = await fixture.dependencies.makeMenuActivityCommands().handle(.runManually())

        // The stubbed sync finds nothing — the run completes as a no-op,
        // proving submission was reached through the menu wiring.
        #expect(result.status == .noOp)
    }

    @Test("identical activity facts keep the revision")
    func activityRefreshDedups() async {
        let dependencies = makeDependencies()
        let facts = makeLibraryFacts(tracks: [])

        let first = await dependencies.refreshActivityProjection(
            library: facts,
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        )
        let second = await dependencies.refreshActivityProjection(
            library: facts,
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        )

        #expect(second.revision == first.revision)
    }

    @Test("the host holds no product-truth state beyond the allowlist")
    func hostStateAllowlist() throws {
        // The slice exit pin: every remaining @State is a projection
        // mirror, a browse adapter cache, a backend query RESULT, or UI
        // ephemera. workflowViewModel is the LAST handover item — new
        // product truth must land on the dependency graph, never here.
        let allowlist: Set = [
            "activityProjection", "reportsProjection", "fixPlanProjection",
            "chromeProjection", "browseProjection",
            "artistCatalogFeed",
            "analyticsSnapshot", "analyticsWindow",
            "browseDesignArtists", "browseDesignScope", "browseRowIndex", "browseReadSource",
            "selectedRunReport", "runReportDetailRequestID",
            "selectedRoute", "hasStartedInitialLoad",
            "workflowViewModel", "workflowNoticeMessage",
            "activityCommandNoticeMessage", "activityCommandNoticeID",
            "fixPlanNoticeMessage", "fixPlanNoticeTone", "fixPlanNoticeID",
            "reportNotice", "reportNoticeID",
            "browseCommandNotice", "isReviewBusy", "isDismissalBusy",
        ]
        let source = try String(contentsOf: libraryLoadSourceURL(), encoding: .utf8)
        let declared = source.split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "@State private var ") else { return nil }
                // A multi-binding line would parse as ONE name and count
                // as ONE raw occurrence — reject the shape outright so
                // the tripwire cannot weaken silently.
                #expect(!line.contains(","), "multi-binding @State line: \(line)")
                let tail = line[range.upperBound...]
                return tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }.description
            }

        #expect(!declared.isEmpty)
        // Every @State in the file must parse into `declared` — a
        // declaration shape the parser misses would weaken the tripwire
        // silently.
        let rawStateCount = source.components(separatedBy: "@State ").count - 1
        #expect(declared.count == rawStateCount)
        for name in declared {
            #expect(allowlist.contains(name), "\(name) is not an allowed host @State")
        }
    }

    @Test("a closed window publishes honest idle, never a stale phase")
    func closedWindowPublishesHonestIdle() async throws {
        // The A8 pin: a provider whose VM died must NOT re-emit the last
        // cached processing phase — publishes read .empty by construction.
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.workflowFactsProvider = {
            ActivityWorkflowFacts(
                dashboard: WorkflowDashboardState(
                    proposedChangeCount: 0, acceptedChangeCount: 0, failedWriteCount: 0,
                    isProcessing: true, phaseLabel: "Scanning"
                ),
                pendingVerification: nil
            )
        }
        _ = await fixture.dependencies.republishActivityProjection()

        // Window death: the provider slot clears (registration is
        // per-window); the next boundary republish must go idle.
        fixture.dependencies.workflowFactsProvider = nil
        let published = await fixture.dependencies.republishActivityProjection()

        #expect(published.subtitle != "Scanning")
        #expect(published.healthFacts.readyUpdateCount == 0)
    }

    @Test("a boundary republish reads fresh workflow facts")
    func boundaryPublishReadsFreshWorkflowFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let phase = PhaseBox()
        fixture.dependencies.workflowFactsProvider = {
            ActivityWorkflowFacts(
                dashboard: WorkflowDashboardState(
                    proposedChangeCount: 0, acceptedChangeCount: phase.accepted, failedWriteCount: 0,
                    isProcessing: false, phaseLabel: "Idle"
                ),
                pendingVerification: nil
            )
        }
        _ = await fixture.dependencies.republishActivityProjection()

        // The VM mutates with NO host onChange in between — the next
        // publish still carries the new value (no stale cache).
        phase.accepted = 7
        let published = await fixture.dependencies.republishActivityProjection()

        #expect(published.healthFacts.readyUpdateCount == 7)
    }

    @Test("a republish derives report facts from the persisted change log")
    func republishDerivesReportFacts() async throws {
        // The chart cluster is builder truth fed by the bounded store
        // read — no view fetch exists on this path anymore (P8/D3).
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let store = try ChangeLogDataStore(modelContainer: ModelContainerFactory.createInMemory())
        try await store.saveEntry(Core.ChangeLogEntry(
            changeType: .genreUpdate, trackID: "t-1", artist: "Clutch"
        ))
        fixture.dependencies.installTestChangeLogStore(store)

        let published = await fixture.dependencies.refreshActivityProjection(
            library: makeLibraryFacts(tracks: []),
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        )

        #expect(published.reportFacts.stats.processed == 1)
        #expect(published.reportFacts.changeLog.first?.artist == "Clutch")
    }

    @Test("one fact set feeds the snapshot and the projection")
    func activityFactsFeedBothPaths() async {
        // F4: the design snapshot reads the SAME ActivityLibraryFacts
        // value the backend publish caches — now-independent facts agree
        // within one render by construction.
        let dependencies = makeDependencies()
        let facts = makeLibraryFacts(tracks: [
            Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant", genre: "Rock", year: 2004),
        ])

        let published = await dependencies.refreshActivityProjection(
            library: facts,
            workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        )
        let snapshot = ActivitySnapshotAdapter.makeSnapshot(
            from: DesignActivitySnapshotInput(
                library: facts,
                workflow: ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil),
                settings: .preview,
                now: Date(timeIntervalSince1970: 100)
            ),
            activityProjection: published
        )

        #expect(snapshot.health.totalTracks == facts.tracks.count)
        #expect(snapshot.health.totalTracks == published.healthFacts.counts.totalTracks)
        #expect(snapshot.dryRun.tracks == facts.tracks.count)
    }

    @Test("a subscription made before initialize receives boundaries")
    func subscriptionBeforeInitializeReceivesBoundaries() async throws {
        // The exact race that used to return a permanently dead
        // .finished stream: the window's .task subscribes before the
        // orchestrator exists.
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let updates = await fixture.dependencies.runLifecycleUpdates()
        let terminalTask = Task { await firstTerminal(in: updates) }

        fixture.dependencies.installTrackCountSource { 1 }
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))
        _ = await fixture.dependencies.makeMenuActivityCommands().handle(.runManually())

        let terminal = await terminalTask.value
        #expect(terminal?.state == .completedNoOp)
    }

    @Test("a subscription survives an orchestrator rebuild")
    func subscriptionSurvivesOrchestratorRebuild() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.installTrackCountSource { 1 }
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))

        let updates = await fixture.dependencies.runLifecycleUpdates()
        let terminalTask = Task { await firstTerminal(in: updates) }

        // A runtime-apply rebuild replaces the orchestrator; the SAME
        // subscription must keep delivering (it used to die silently).
        await fixture.dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, _ in .empty }
        )))
        _ = await fixture.dependencies.makeMenuActivityCommands().handle(.runManually())

        let terminal = await terminalTask.value
        #expect(terminal?.state == .completedNoOp)
    }

    @Test("report detail is served by a backend query")
    func reportDetailServedByBackend() async throws {
        let runID = RunID()
        let record = sampleRunRecord(runID: runID)
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(storedRecord: record)
        )

        let detail = await fixture.dependencies.loadRunReportDetail(runID: runID.rawValue.uuidString)

        #expect(detail?.runID == runID.rawValue.uuidString)
        #expect(detail?.stateLabel.isEmpty == false)
    }

    @Test("continuation lineage flows through the backend query")
    func reportDetailCarriesContinuations() async throws {
        let runID = RunID()
        let continuation = RunID()
        let store = RunRecordStoreStub(storedRecord: sampleRunRecord(runID: runID))
        await store.installContinuations([continuation])
        let fixture = try makeFixture(testArtists: [], runRecordStore: store)

        let detail = await fixture.dependencies.loadRunReportDetail(runID: runID.rawValue.uuidString)

        let lineage = try #require(detail?.lineageLines)
        #expect(lineage.contains { $0.hasPrefix("Continued by") })
    }

    @Test("a missing record yields no detail")
    func reportDetailMissingRecord() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())

        let detail = await fixture.dependencies.loadRunReportDetail(runID: RunID().rawValue.uuidString)

        #expect(detail == nil)
    }

    @Test("an open recovery record serves detail through the backend")
    func reportDetailOpenRecoveryRecord() async throws {
        // The backend query reads active-run truth from the orchestrator
        // accessor (the F3 rule, pinned for the list by
        // reportsRefreshHeadless) — no view state exists on this path.
        // The active-vs-inactive dismissal gate itself is pinned at
        // builder level (ReportDetailBuilderTests).
        let runID = RunID()
        let record = sampleRunRecord(
            runID: runID,
            intent: .writeFixes,
            state: .recoverable,
            recoveryID: UUID(),
            finishedAt: nil
        )
        let fixture = try makeFixture(
            testArtists: [],
            runRecordStore: RunRecordStoreStub(storedRecord: record)
        )

        let detail = await fixture.dependencies.loadRunReportDetail(runID: runID.rawValue.uuidString)

        #expect(detail != nil)
        // No work items on the fixture record: dismissal must stay closed
        // even in the recoverable state (builder truth passed through).
        #expect(detail?.canDismissItems == false)
    }
}

@MainActor
private final class PhaseBox {
    var accepted = 0
}

private final class CurrentFlagSequence: @unchecked Sendable {
    private var values: [Bool]

    init(values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        values.isEmpty ? false : values.removeFirst()
    }
}

private func firstTerminal(in updates: LifecycleUpdates) async -> RunLifecycleSnapshot? {
    for await lifecycle in updates where !lifecycle.isActive {
        return lifecycle
    }
    return nil
}
