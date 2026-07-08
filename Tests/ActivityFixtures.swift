import Core
import Foundation
import Services
@testable import Genre_Updater

enum ActivityFixtures {
    static let recoveryRunIDString = "00000000-0000-0000-0000-000000000097"
    static let recoveryRunID = RunID(rawValue: UUID(uuidString: recoveryRunIDString) ?? UUID())
    static let finishDate = Date(timeIntervalSince1970: 101)

    static func makeManualProjection(
        revision: ProjectionRevision,
        isEnabled: Bool
    ) -> ActivityProjection {
        ActivityProjection(
            revision: revision,
            title: "Library ready",
            subtitle: "Library ready",
            syncStatusText: "Synced just now",
            currentStage: .detect,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: nil,
            secondaryCommand: ActivityCommandDescriptor(
                id: "run-manually",
                title: "Run manually",
                style: .secondary,
                isEnabled: isEnabled,
                commandKind: .runManually
            ),
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )
    }

    static func makeRecoveryProjection(
        revision: ProjectionRevision,
        runID: String = recoveryRunIDString,
        isSecondaryEnabled: Bool = true
    ) -> ActivityProjection {
        ActivityProjection(
            revision: revision,
            title: "Recovery needed",
            subtitle: "Previous run needs recovery before writes continue",
            syncStatusText: "Recovery needed",
            currentStage: .fix,
            processingMode: .preview,
            automationState: .manualScanOnly,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: ActivityCommandDescriptor(
                id: "resume-recovery",
                title: "Resume safely",
                style: .primary,
                isEnabled: true,
                commandKind: .resumeRecovery
            ),
            secondaryCommand: ActivityCommandDescriptor(
                id: "run-manually",
                title: "Check library",
                style: .secondary,
                isEnabled: isSecondaryEnabled,
                commandKind: .runManually,
                variant: .libraryCheck
            ),
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: [
                OperationalIssue(
                    id: "recovery-needed",
                    category: .recoveryRequired,
                    summary: "Previous run needs recovery",
                    technicalDetail: runID
                )
            ]
        )
    }

    @MainActor
    final class Harness {
        var isRunOrchestratorAvailable: Bool
        var submitRunCallCount = 0
        var reloadCallCount = 0
        var refreshCallCount = 0
        var preflightRunIDs: [RunID] = []
        var queuedReloadBarriers: [RunID] = []

        private var projection: ActivityProjection
        private let preflightOutcome: RecoveryPreflightOutcome?
        private let runResult: RunSubmissionResult
        private let runError: Error?

        init(
            currentRevision: ProjectionRevision = ProjectionRevision(1),
            projection: ActivityProjection? = nil,
            isRunOrchestratorAvailable: Bool = true,
            preflightOutcome: RecoveryPreflightOutcome? = nil,
            runResult: RunSubmissionResult? = nil,
            runError: Error? = nil
        ) {
            self.projection = projection ?? makeManualProjection(revision: currentRevision, isEnabled: true)
            self.isRunOrchestratorAvailable = isRunOrchestratorAvailable
            self.preflightOutcome = preflightOutcome
            self.runResult = runResult ?? .completedNoOp(lifecycle(
                phase: .finished(.completedNoOp(SyncResult()), finishedAt: finishDate)
            ))
            self.runError = runError
        }

        func makeCommands() -> ActivityCommands {
            ActivityCommands(
                isRunOrchestratorAvailable: { self.isRunOrchestratorAvailable },
                submitManualRun: {
                    self.submitRunCallCount += 1
                    if let runError = self.runError {
                        throw runError
                    }
                    return self.runResult
                },
                queueManualReload: { runID in
                    self.queuedReloadBarriers.append(runID)
                },
                reloadLibrary: { forceRefresh in
                    if forceRefresh {
                        self.reloadCallCount += 1
                    }
                },
                refreshActivityProjection: {
                    self.refreshCallCount += 1
                    self.projection = self.projection.withRevision(self.projection.revision.advanced())
                    return self.projection
                },
                runRecoveryPreflight: { runID in
                    self.preflightRunIDs.append(runID)
                    return self.preflightOutcome ?? .inspectable(runID: runID, state: .syncingLibrary)
                },
                currentFixPlanID: {
                    "plan-1"
                }
            )
        }
    }

    static func lifecycle(
        phase: RunPhase,
        runID: RunID = RunID(),
        trigger: RunTrigger = .manualCheck,
        intent: RunIntent = .observeLibrary
    ) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: runID,
            requestID: RunRequestID(),
            trigger: trigger,
            intent: intent,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 75,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: trigger.rawValue
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            phase: phase
        )
    }
}
