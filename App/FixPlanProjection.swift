import Core
import Foundation
import Services

extension AppDependencies {
    func refreshFixPlanProjection(for lifecycle: RunLifecycleSnapshot? = nil) async -> FixPlanProjection {
        let inputGeneration = await projectionStore.nextFixPlanInputGeneration()
        let projection: FixPlanProjection
        do {
            let latest = try await latestFixPlanProjection()
            projection = try await visibleFixPlanProjection(
                latest.projection,
                createdAt: latest.createdAt,
                after: lifecycle
            )
        } catch {
            projection = .unavailable(message: error.localizedDescription)
        }
        return await projectionStore.replaceFixPlanProjection(projection, inputGeneration: inputGeneration)
    }

    func clearFixPlanProjection() async -> FixPlanProjection {
        let inputGeneration = await projectionStore.nextFixPlanInputGeneration()
        return await projectionStore.replaceFixPlanProjection(.empty(), inputGeneration: inputGeneration)
    }

    private func visibleFixPlanProjection(
        _ projection: FixPlanProjection,
        createdAt: Date?,
        after lifecycle: RunLifecycleSnapshot?
    ) async throws -> FixPlanProjection {
        guard projection.status != .unavailable else { return projection }

        if let lifecycle {
            guard lifecycle.syncResult?.hasMirrorChanges == true,
                  projection.sourceRunID != lifecycle.runID
            else { return projection }
            return .empty()
        }

        guard let createdAt, let runRecordStore else { return projection }
        let laterRuns = try await runRecordStore.reports(matching: RunReportQuery(startedAfter: createdAt))
        guard laterRuns.skippedCorruptedCount == 0 else {
            throw FixPlanProjectionLoadError.corruptedRunHistory
        }
        guard laterRuns.records.contains(where: { $0.syncSummary?.hasMirrorChanges == true }) else {
            return projection
        }

        return .empty()
    }

    private func latestFixPlanProjection() async throws -> (projection: FixPlanProjection, createdAt: Date?) {
        guard let fixPlanStore else {
            return (.empty(), nil)
        }
        guard let plan = try await fixPlanStore.latestPlan() else {
            return (.empty(), nil)
        }
        guard let decision = try await fixPlanStore.currentDecision(for: plan.id) else {
            return (
                .unavailable(message: "Review decision is missing for fix plan \(plan.id.rawValue.uuidString)"),
                plan.createdAt
            )
        }

        let now = Date()
        let currentScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: nil,
            createdAt: now,
            reason: "fixPlanProjectionRefresh"
        )
        let currentConfiguration = captureFixPlanConfig(
            at: now,
            hasDiscogsAccess: isDiscogsAccessAvailable ?? plan.configuration.hasDiscogsAccess,
            // The album target is the plan's identity, not a live setting:
            // staleness must compare the rest of the configuration against
            // the same target, or every targeted plan is instantly stale.
            albumTarget: plan.configuration.albumTarget
        )
        return (
            FixPlanProjector.makeProjection(
                plan: plan,
                decision: decision,
                staleness: FixPlanStaleness.evaluate(
                    plan: plan,
                    currentScope: currentScope,
                    currentConfiguration: currentConfiguration
                )
            ),
            plan.createdAt
        )
    }
}

private enum FixPlanProjectionLoadError: LocalizedError {
    case corruptedRunHistory

    var errorDescription: String? {
        "Fix plan freshness could not be verified because newer run history is corrupted."
    }
}
