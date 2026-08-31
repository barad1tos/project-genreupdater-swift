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
                sourceMirrorRevision: latest.sourceMirrorRevision,
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
        sourceMirrorRevision: MirrorRevision?,
        after lifecycle: RunLifecycleSnapshot?
    ) async throws -> FixPlanProjection {
        guard projection.status == .ready || projection.status == .stale else { return projection }

        if let lifecycle,
           lifecycle.syncResult?.hasMirrorChanges == true,
           projection.sourceRunID != lifecycle.runID {
            return .empty()
        }

        guard let sourceMirrorRevision else {
            throw FixPlanProjectionLoadError.unboundPlan
        }
        guard let trackStore else {
            throw FixPlanProjectionLoadError.mirrorUnavailable
        }
        let mirror = try await trackStore.loadMirrorSnapshot()
        guard sourceMirrorRevision < mirror.contentRevision else { return projection }

        return .empty()
    }

    private func latestFixPlanProjection() async throws -> (
        projection: FixPlanProjection,
        sourceMirrorRevision: MirrorRevision?
    ) {
        guard let fixPlanStore else {
            return (.empty(), nil)
        }
        guard let plan = try await fixPlanStore.latestPlan() else {
            return (.empty(), nil)
        }
        guard let decision = try await fixPlanStore.currentDecision(for: plan.id) else {
            return (
                .unavailable(message: "Review decision is missing for fix plan \(plan.id.rawValue.uuidString)"),
                plan.scope.mirrorRevision
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
            plan.scope.mirrorRevision
        )
    }
}

private enum FixPlanProjectionLoadError: LocalizedError {
    case mirrorUnavailable
    case unboundPlan

    var errorDescription: String? {
        switch self {
        case .mirrorUnavailable:
            "Fix plan freshness could not be verified because the library mirror is unavailable."
        case .unboundPlan:
            "Fix plan freshness could not be verified because the plan is not bound to a library revision."
        }
    }
}
