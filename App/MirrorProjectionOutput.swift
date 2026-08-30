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
        _ = await dependencies.refreshFixPlanProjection()
        await dependencies.refreshReportsProjection()
        await dependencies.republishActivityProjection()
        await dependencies.refreshChromeProjection()
    }
}

@MainActor
final class AppMirrorEffectReporter: MirrorEffectDrainReporting {
    private weak var dependencies: AppDependencies?

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func reportMirrorEffectFailure(_ detail: String) async {
        guard let dependencies else { return }
        dependencies.mirrorEffectDrainIssue = OperationalIssue(
            id: "mirror-effect-drain",
            category: .temporaryUnavailable,
            summary: "Some library views may be stale",
            technicalDetail: detail,
            nextAction: "Try the library refresh again."
        )
        await dependencies.republishActivityProjection()
        AppLogger.make(category: "mirror-effects").error(
            "Pending mirror effects could not be applied: \(detail, privacy: .public)"
        )
    }

    func clearMirrorEffectFailure() async {
        guard let dependencies, dependencies.mirrorEffectDrainIssue != nil else { return }
        dependencies.mirrorEffectDrainIssue = nil
        await dependencies.republishActivityProjection()
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
