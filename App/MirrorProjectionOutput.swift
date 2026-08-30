import Core
import OSLog
import Services

@MainActor
final class AppMirrorProjectionOutput: MirrorProjectionOutput {
    private weak var dependencies: AppDependencies?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func refreshMirrorProjections() async throws {
        guard let dependencies else {
            throw MirrorEffectDrainError.projectionOutputUnavailable
        }
        try await dependencies.reloadMirrorFacts()
        _ = try await dependencies.refreshFixPlanFromStore()
        guard await dependencies.refreshReportsProjection() != nil else {
            throw AppMirrorProjectionError.reportsUnavailable
        }
        _ = try await dependencies.republishActivityWithFreshHistory()
        await dependencies.refreshChromeProjection()
    }
}

private enum AppMirrorProjectionError: LocalizedError {
    case reportsUnavailable

    var errorDescription: String? {
        "Mirror-dependent reports could not be refreshed"
    }
}

@MainActor
final class AppMirrorEffectReporter: MirrorEffectDrainReporting {
    private weak var dependencies: AppDependencies?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func reportMirrorEffectFailure(_ failure: MirrorEffectDrainFailure) async {
        guard let dependencies else { return }
        dependencies.mirrorEffectDrainIssue = Self.issue(for: failure)
        await dependencies.republishActivityProjection()
        AppLogger.make(category: "mirror-effects").error(
            "Pending mirror effects could not be applied: \(failure.detail, privacy: .private)"
        )
    }

    func clearMirrorEffectFailure() async {
        guard let dependencies, dependencies.mirrorEffectDrainIssue != nil else { return }
        dependencies.mirrorEffectDrainIssue = nil
        await dependencies.republishActivityProjection()
    }

    private static func issue(for failure: MirrorEffectDrainFailure) -> OperationalIssue {
        switch failure.kind {
        case .temporary:
            OperationalIssue(
                id: "mirror-effect-drain",
                category: .temporaryUnavailable,
                summary: "Some library views may be stale",
                technicalDetail: failure.detail,
                nextAction: "Try the library refresh again."
            )
        case .corruptedQueue:
            OperationalIssue(
                id: "mirror-effect-drain",
                category: .internalFailure,
                summary: "The library refresh queue needs repair",
                technicalDetail: failure.detail,
                nextAction: "Contact support to repair the local library database."
            )
        }
    }
}

extension AppDependencies {
    func installMirrorEffectDrain(store: any TrackStateStore, cache: any CacheService) async {
        let projectionOutput = AppMirrorProjectionOutput(dependencies: self)
        mirrorProjectionOutput = projectionOutput
        mirrorEffectDrain = MirrorEffectDrain(
            store: store,
            cache: cache,
            snapshot: librarySnapshotService,
            projections: projectionOutput,
            reporter: AppMirrorEffectReporter(dependencies: self)
        )
        await drainMirrorEffectsReportingFailure()
    }

    /// Applies durable post-commit work without making committed mirror truth unavailable.
    func drainMirrorEffectsReportingFailure() async {
        await mirrorEffectDrain?.drain()
    }
}
