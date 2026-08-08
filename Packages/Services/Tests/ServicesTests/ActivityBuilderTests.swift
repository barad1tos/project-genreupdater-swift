import Core
import Foundation
import Services
import Testing

@Suite("ActivityBuilder")
struct ActivityBuilderTests {
    private let scanDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_480)

    @Test("empty activity projection preserves revision and disabled manual command")
    func emptyActivityProjectionPreservesRevisionAndDisabledManualCommand() {
        let projection = ActivityProjection.empty(revision: ProjectionRevision(11))

        #expect(projection.revision == ProjectionRevision(11))
        #expect(projection.title == "Activity")
        #expect(projection.status(for: .watch) == .pending)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("ready library exposes run manually command")
    func readyLibraryExposesRunManuallyCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")]
            )
        )

        #expect(projection.revision == .initial)
        #expect(projection.title == "Library ready")
        #expect(projection.subtitle == "Library ready")
        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.currentStage == .detect)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
    }

    @Test("loading library without a run keeps the scanning title")
    func loadingLibraryWithoutRunKeepsScanningTitle() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .loading
            )
        )

        #expect(projection.title == "Scanning library")
    }

    @Test("failed library state does not mark watch completed")
    func failedLibraryStateDoesNotMarkWatchCompleted() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [],
                libraryState: .failed("Music.app is unavailable")
            )
        )

        #expect(projection.title == "Library needs attention")
        #expect(projection.status(for: .watch) == .failed)
        #expect(projection.status(for: .detect) == .failed)
    }

    @Test("proposed fixes expose review primary command")
    func proposedFixesExposeReviewPrimaryCommand() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 3,
                    acceptedChangeCount: 0,
                    failedWriteCount: 0,
                    isProcessing: false,
                    phaseLabel: "Idle"
                )
            )
        )

        let primaryCommand = try #require(projection.primaryCommand)
        #expect(primaryCommand.id == "review-changes")
        #expect(primaryCommand.title == "Review changes")
        #expect(primaryCommand.style == .primary)
        #expect(primaryCommand.isEnabled)
        #expect(primaryCommand.commandKind == .reviewChanges)
        #expect(projection.secondaryCommand?.commandKind == .runManually)
    }

    @Test("fix plan summary exposes review state without workflow counts")
    func usesFixPlanSummary() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 4,
                    acceptedCount: 3,
                    canApply: true
                )
            )
        )

        let deltaCard = projection.summaryCards.first { $0.id == "delta" }
        let primaryCommand = projection.primaryCommand

        #expect(projection.title == "Fix plan ready")
        #expect(projection.subtitle == "4 candidate fixes · preview mode · no Music tags written")
        #expect(projection.deltaCount == 4)
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .diff) == .completed)
        #expect(projection.status(for: .fix) == .gated)
        #expect(deltaCard?.value == "4")
        #expect(deltaCard?.detail == "candidate fixes")
        #expect(primaryCommand?.commandKind == .reviewChanges)
    }

    @Test("recovery summary takes precedence over fix plan review")
    func recoverySummaryPriority() throws {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 4,
                    acceptedCount: 3,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1")
            )
        )

        let issue = try #require(projection.operationalIssues.first)

        #expect(projection.title == "Recovery needed")
        #expect(projection.subtitle == "Previous run needs recovery before writes continue")
        #expect(projection.syncStatusText == "Recovery needed")
        #expect(projection.currentStage == .fix)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.primaryCommand?.id == "resume-recovery")
        #expect(projection.primaryCommand?.title == "Resume safely")
        #expect(projection.primaryCommand?.style == .primary)
        #expect(projection.primaryCommand?.isEnabled == true)
        #expect(projection.primaryCommand?.commandKind == .resumeRecovery)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Check library")
        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(issue.category == .recoveryRequired)
        #expect(issue.summary == "Previous run needs recovery")
    }

    @Test("recovery hold queues library check during active background run")
    func recoveryQueuesCheck() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1"),
                environment: InputEnvironment(runLifecycle: lifecycle(
                    phase: .active(.syncingLibrary),
                    trigger: .backgroundSync
                ))
            )
        )

        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Queue library check")
        #expect(projection.secondaryCommand?.variant == .libraryCheck)
        #expect(projection.secondaryCommand?.isEnabled == true)
        #expect(projection.operationalIssues.first?.category == .recoveryRequired)
    }

    @Test("library blockers take precedence over recovery summary")
    func blocksRecoverySummary() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1")
            )
        )

        #expect(projection.title == "Library needs attention")
        #expect(projection.subtitle == "Music access denied")
        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.currentStage == .detect)
        #expect(projection.status(for: .fix) == .gated)
        #expect(projection.secondaryCommand?.id == "run-manually")
        #expect(projection.secondaryCommand?.title == "Run manually")
        #expect(projection.secondaryCommand?.variant == .standard)
        #expect(projection.operationalIssues.first?.category == .musicPermissionRequired)
        #expect(projection.operationalIssues.first?.summary == "Music permission required")
        #expect(projection.operationalIssues.allSatisfy { $0.category != .recoveryRequired })
    }

    @Test("library blocker suppresses review command during recovery")
    func blocksReviewCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1")
            )
        )

        #expect(projection.primaryCommand == nil)
        #expect(projection.operationalIssues.first?.category == .musicPermissionRequired)
        #expect(projection.operationalIssues.allSatisfy { $0.category != .recoveryRequired })
    }

    @Test("library blocker gates auto-fix status during recovery")
    func gatesAutoFix() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                fixPlan: ActivityFixPlanSummary(
                    status: .ready,
                    itemCount: 2,
                    acceptedCount: 0,
                    canApply: true
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1"),
                environment: InputEnvironment(processingMode: .autoFix)
            )
        )

        #expect(projection.status(for: .fix) == .gated)
    }

    @Test("recovery gates failed writes during library blocker")
    func gatesFailedWrites() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                libraryState: .permissionDenied("Music access denied"),
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 1,
                    isProcessing: false,
                    phaseLabel: "Idle"
                ),
                recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: "run-1")
            )
        )

        #expect(projection.status(for: .fix) == .gated)
    }

    @Test("summary cards expose semantic kinds instead of UI symbols")
    func summaryCardsExposeSemanticKindsInsteadOfUISymbols() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(tracks: [editableTrack(id: "1")])
        )

        #expect(projection.summaryCards.map(\.kind) == [.automation, .delta, .quality])
    }

    @Test("recent last scan status says synced just now")
    func recentLastScanStatusSaysSyncedJustNow() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                environment: InputEnvironment(
                    lastScanDate: now.addingTimeInterval(-30),
                    now: now
                )
            )
        )

        #expect(projection.syncStatusText == "Synced just now")
    }

    @Test("metrics snapshot date backs sync status when explicit scan date is missing")
    func metricsSnapshotDateBacksSyncStatusWhenExplicitScanDateIsMissing() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                environment: InputEnvironment(
                    lastScanDate: nil,
                    metrics: ActivityProjectionMetrics(
                        totalTracks: 1,
                        tracksWithGenre: 1,
                        tracksWithYear: 1,
                        tracksWithBoth: 1,
                        protectedFileCount: 0,
                        recentlyAdded: 0,
                        snapshotDate: scanDate
                    ),
                    usesDefaultScanDate: false
                )
            )
        )

        #expect(projection.syncStatusText == "Synced 8m ago")
        #expect(projection.automationState == .manualScanOnly)
    }

    @Test("projection derives intervention, failed writes, and scan activity from input")
    func projectionDerivesInterventionFailedWritesAndScanActivityFromInput() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1"), editableTrack(id: "2"), editableTrack(id: "3")],
                workflow: ActivityWorkflowState(
                    proposedChangeCount: 0,
                    acceptedChangeCount: 0,
                    failedWriteCount: 2,
                    isProcessing: false,
                    phaseLabel: "Review"
                ),
                pendingVerification: ActivityPendingVerificationSummary(
                    total: 142,
                    due: 12,
                    problematic: 3,
                    skippedByInterval: 5,
                    verified: 7
                )
            )
        )

        #expect(projection.interventionCount == 142)
        #expect(projection.failedWriteCount == 2)
        #expect(projection.status(for: .fix) == .failed)
        #expect(projection.recentActivity.first?.title == "Library scan")
        #expect(projection.recentActivity.first?.detail == "3 tracks analyzed")
    }

    @Test("library sync unavailable disables run manually command")
    func librarySyncUnavailableDisablesRunManuallyCommand() {
        let projection = ActivityBuilder.makeProjection(
            from: makeInput(
                tracks: [editableTrack(id: "1")],
                environment: InputEnvironment(isLibrarySyncAvailable: false)
            )
        )

        #expect(projection.secondaryCommand?.commandKind == .runManually)
        #expect(projection.secondaryCommand?.isEnabled == false)
    }

    @Test("scan facts pin the label vocabulary and precedence")
    func scanFactsVocabulary() {
        let now = Date(timeIntervalSince1970: 1_800_000_060)
        // Precedence: the LIVE scan date wins over the cached metrics
        // timestamp when both exist (strictly fresher).
        let both = ActivityBuilder.makeProjection(from: makeInput(environment: InputEnvironment(
            lastScanDate: Date(timeIntervalSince1970: 1_800_000_000),
            metrics: ActivityProjectionMetrics(
                totalTracks: 10, tracksWithGenre: 5, tracksWithYear: 5, tracksWithBoth: 5,
                protectedFileCount: 0, recentlyAdded: 0,
                snapshotDate: Date(timeIntervalSince1970: 1_799_996_400)
            ),
            now: now
        )))
        #expect(both.scanFacts.lastScanLabel == "1m ago")

        // Album count contract: nil = metrics-backed without identity;
        // 0 = neither metrics nor tracks; counted when tracks exist.
        #expect(both.scanFacts.albumCount == nil)
        let neither = ActivityBuilder.makeProjection(from: makeInput(environment: InputEnvironment(
            usesDefaultScanDate: false
        )))
        #expect(neither.scanFacts.albumCount == 0)
        #expect(neither.scanFacts.lastScanLabel == "No scan yet")
        let counted = ActivityBuilder.makeProjection(from: makeInput(
            tracks: [editableTrack(id: "a"), editableTrack(id: "b")]
        ))
        #expect(counted.scanFacts.albumCount == 1)
    }

    @Test("next-run labels cover both triggers across run phases")
    func nextRunLabelTriggerTable() {
        let cases: [(RunTrigger, RunPhase, String)] = [
            (.manualCheck, .active(.writing), "Manual sync running"),
            (.backgroundSync, .active(.writing), "Run in progress"),
            (.manualCheck, .suspended(.blocked), "Manual sync blocked"),
            (.backgroundSync, .suspended(.blocked), "Run blocked"),
            (.manualCheck, .suspended(.recoverable), "Manual sync needs recovery"),
            (.backgroundSync, .suspended(.recoverable), "Recovery needed"),
            (.manualCheck, .finished(.failed(message: "x"), finishedAt: scanDate), "Manual sync failed"),
            (.backgroundSync, .finished(.failed(message: "x"), finishedAt: scanDate), "Run failed"),
            (.manualCheck, .finished(.cancelled(message: "x"), finishedAt: scanDate), "Manual sync cancelled"),
            (.backgroundSync, .finished(.cancelled(message: "x"), finishedAt: scanDate), "Run cancelled"),
        ]

        for (trigger, phase, expected) in cases {
            let lifecycle = RunLifecycleSnapshot(
                runID: RunID(),
                requestID: RunRequestID(),
                trigger: trigger,
                intent: .observeLibrary,
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: [],
                    knownTrackCount: nil,
                    createdAt: scanDate,
                    reason: "scan-facts-test"
                ),
                startedAt: scanDate,
                phase: phase
            )
            let projection = ActivityBuilder.makeProjection(from: makeInput(environment: InputEnvironment(
                runLifecycle: lifecycle
            )))
            #expect(projection.scanFacts.nextRunLabel == expected, "\(trigger) \(phase)")
        }

        // Completed terminals fall back to the automation ladder.
        let completed = ActivityBuilder.makeProjection(from: makeInput(environment: InputEnvironment(
            runLifecycle: nil
        )))
        #expect(completed.scanFacts.nextRunLabel == "Manual scan only")
    }

    @Test("health facts derive from live tracks with the editability scan")
    func healthFactsFromTracks() {
        let tracks = [
            track(id: "both", genre: "Rock", year: 2001, status: "purchased"),
            track(id: "genre-only", genre: "Rock", year: nil, status: "purchased"),
            track(id: "year-only", genre: "   ", year: 2002, status: "purchased"),
            track(id: "protected", genre: nil, year: nil, status: "prerelease"),
        ]
        let workflow = ActivityWorkflowState(
            proposedChangeCount: 0, acceptedChangeCount: 3, failedWriteCount: 0,
            isProcessing: false, phaseLabel: "Idle"
        )

        let projection = ActivityBuilder.makeProjection(from: makeInput(tracks: tracks, workflow: workflow))
        let facts = projection.healthFacts

        #expect(facts.counts.totalTracks == 4)
        #expect(facts.counts.tracksWithGenre == 2)
        #expect(facts.counts.tracksWithYear == 2)
        #expect(facts.counts.tracksWithBoth == 1)
        #expect(facts.missingGenreCount == 2)
        #expect(facts.missingYearCount == 2)
        #expect(facts.counts.protectedFileCount == 1)
        #expect(facts.counts.isProtectedFileCountKnown)
        #expect(facts.readyUpdateCount == 3)
        #expect(facts.genreCoverageRatio == 0.5)
        #expect(facts.yearCoverageRatio == 0.5)
        #expect(facts.consistencyCoverageRatio == 0.25)
        #expect(facts.editableCoverageRatio == 0.75)
        // 0.5*0.35 + 0.5*0.35 + 0.25*0.30 = 0.425, minus the protected
        // penalty (1/4)*0.25 = 0.0625 — the verbatim dashboard formula.
        #expect(abs(facts.healthScore - 0.3625) < 0.0001)
        #expect(facts.healthPercentage == 36)
        // The live-tracks branch now runs the real editability scan — the
        // projection's protected count agrees with the dashboard truth.
        #expect(projection.protectedCount == 1)
    }

    @Test("health facts prefer cached metrics and honor unknown editability")
    func healthFactsFromMetrics() {
        let metrics = ActivityProjectionMetrics(
            totalTracks: 10, tracksWithGenre: 8, tracksWithYear: 6, tracksWithBoth: 5,
            protectedFileCount: nil, recentlyAdded: 2, snapshotDate: scanDate
        )
        let workflow = ActivityWorkflowState(
            proposedChangeCount: 0, acceptedChangeCount: 2, failedWriteCount: 1,
            isProcessing: false, phaseLabel: "Idle"
        )

        let facts = ActivityBuilder.makeProjection(from: makeInput(
            workflow: workflow,
            environment: InputEnvironment(metrics: metrics)
        )).healthFacts

        #expect(facts.counts.totalTracks == 10)
        #expect(facts.missingGenreCount == 2)
        #expect(facts.missingYearCount == 4)
        #expect(facts.counts.protectedFileCount == 0)
        #expect(!facts.counts.isProtectedFileCountKnown)
        #expect(facts.readyUpdateCount == 2)
        #expect(abs(facts.genreCoverageRatio - 0.8) < 0.0001)
        #expect(abs(facts.yearCoverageRatio - 0.6) < 0.0001)
        #expect(facts.consistencyCoverageRatio == 0.5)
        // Unknown editability contributes no ratio and no penalty.
        #expect(facts.editableCoverageRatio == 0)
        // 0.8*0.35 + 0.6*0.35 + 0.5*0.30 = 0.64, minus the capped failed
        // write penalty min((1/10)*2.0, 0.4) = 0.2.
        #expect(abs(facts.healthScore - 0.44) < 0.0001)
        #expect(facts.healthPercentage == 44)
    }

    @Test("mixed editability evidence makes the protected count unknown")
    func healthCountsMixedEditabilityGrid() {
        // The known-flag rule is all-or-nothing: ONE track without
        // editability evidence makes the whole count unknowable.
        let counts = ActivityHealthCounts.make(from: [
            track(id: "protected", genre: "Rock", year: 2001, status: "prerelease"),
            Track(id: "blank", name: "blank", artist: "A", album: "B", trackStatus: "   "),
            Track(id: "unrecognized", name: "odd", artist: "A", album: "B", trackStatus: "mystery-status"),
        ])

        #expect(counts.protectedFileCount == 1)
        #expect(!counts.isProtectedFileCountKnown)
    }

    @Test("the quality card reports the consistency percentage")
    func qualityCardValue() {
        let tracks = [
            track(id: "both", genre: "Rock", year: 2001, status: "purchased"),
            track(id: "genre-only", genre: "Rock", year: nil, status: "purchased"),
            track(id: "year-only", genre: nil, year: 2002, status: "purchased"),
            track(id: "neither", genre: nil, year: nil, status: "purchased"),
        ]

        let projection = ActivityBuilder.makeProjection(from: makeInput(tracks: tracks))

        #expect(projection.summaryCards.first { $0.kind == .quality }?.value == "25%")
    }

    @Test("an empty library scores zero health")
    func healthFactsEmpty() {
        let facts = ActivityBuilder.makeProjection(from: makeInput()).healthFacts

        #expect(facts == .empty)
        #expect(facts.healthScore == 0)
        #expect(facts.counts.isProtectedFileCountKnown)
    }

    private func track(id: String, genre: String?, year: Int?, status: String) -> Track {
        Track(id: id, name: id, artist: "Artist", album: "Album", genre: genre, year: year, trackStatus: status)
    }

    private func makeInput(
        tracks: [Track] = [],
        libraryState: ActivityLibraryState? = nil,
        workflow: ActivityWorkflowState = .empty,
        fixPlan: ActivityFixPlanSummary? = nil,
        recovery: ActivityRecoverySummary? = nil,
        queuedWrite: ActivityQueuedWriteSummary? = nil,
        pendingVerification: ActivityPendingVerificationSummary? = nil,
        environment: InputEnvironment = InputEnvironment()
    ) -> ActivityProjectionInput {
        ActivityProjectionInput(
            tracks: tracks,
            metrics: environment.metrics,
            lastScanDate: environment.lastScanDate ?? (environment.usesDefaultScanDate ? scanDate : nil),
            libraryState: libraryState ?? (tracks.isEmpty ? .empty : .ready),
            processingMode: environment.processingMode,
            workflow: workflow,
            fixPlan: fixPlan,
            recovery: recovery,
            queuedWrite: queuedWrite,
            pendingVerification: pendingVerification,
            runLifecycle: environment.runLifecycle,
            isLibrarySyncAvailable: environment.isLibrarySyncAvailable,
            isAutoSyncRunning: false,
            now: environment.now ?? self.now
        )
    }

    @Test("a queued write surfaces the continue-writes primary command")
    func surfacesContinueWrites() {
        let input = makeInput(
            queuedWrite: ActivityQueuedWriteSummary(planID: "plan-1", isContinuation: false)
        )

        let projection = ActivityBuilder.makeProjection(from: input)

        #expect(projection.primaryCommand?.commandKind == .continueWrites)
        #expect(projection.primaryCommand?.isEnabled == true)
    }

    @Test("an active recovery outranks the queued-write command")
    func recoveryOutranksContinueWrites() {
        let input = makeInput(
            recovery: ActivityRecoverySummary(unresolvedRunCount: 1, latestRecoveryRunID: UUID().uuidString),
            queuedWrite: ActivityQueuedWriteSummary(planID: "plan-1", isContinuation: false)
        )

        let projection = ActivityBuilder.makeProjection(from: input)

        #expect(projection.primaryCommand?.commandKind == .resumeRecovery)
    }

    @Test("a queued write outranks the review-changes command")
    func continueWritesOutranksReview() {
        let input = makeInput(
            workflow: ActivityWorkflowState(
                proposedChangeCount: 3,
                acceptedChangeCount: 0,
                failedWriteCount: 0,
                isProcessing: false,
                phaseLabel: ""
            ),
            queuedWrite: ActivityQueuedWriteSummary(planID: "plan-1", isContinuation: true)
        )

        let projection = ActivityBuilder.makeProjection(from: input)

        #expect(projection.primaryCommand?.commandKind == .continueWrites)
    }

    private struct InputEnvironment {
        var lastScanDate: Date?
        var metrics: ActivityProjectionMetrics?
        var runLifecycle: RunLifecycleSnapshot?
        var processingMode: ActivityProcessingMode = .preview
        var isLibrarySyncAvailable = true
        var usesDefaultScanDate = true
        var now: Date?
    }

    private func editableTrack(id: String) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 2001,
            trackStatus: "purchased"
        )
    }

    private func lifecycle(phase: RunPhase, trigger: RunTrigger) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: trigger,
            intent: .observeLibrary,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 1,
                createdAt: scanDate,
                reason: "manual-check"
            ),
            startedAt: scanDate,
            phase: phase
        )
    }
}
