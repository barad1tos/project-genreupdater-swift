import Testing
@testable import DesignUI

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test
    @MainActor
    func routeNavigationSupportsBackAndForward() {
        let model = AppModel()

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigate(to: .update)

        #expect(model.route == .update)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigateBack()

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
        #expect(model.canNavigateForward)

        model.navigateForward()

        #expect(model.route == .update)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }

    @Test
    @MainActor
    func browseNavigationRestoresFilter() {
        let model = AppModel()

        model.openBrowse(filter: .missingGenre)
        model.navigate(to: .update)
        model.navigateBack()

        #expect(model.route == .browse)
        #expect(model.browseFilter == .missingGenre)
    }

    @Test
    @MainActor
    func duplicateNavigationDoesNotCreateHistory() {
        let model = AppModel()

        model.navigate(to: .activity)

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
    }

    @Test
    @MainActor
    func newNavigationClearsForwardHistory() {
        let model = AppModel()

        model.navigate(to: .update)
        model.navigateBack()
        model.navigate(to: .reports)

        #expect(model.route == .reports)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }

    @Test
    @MainActor
    func casualExperienceRedirectsAnalyticsWithoutChangingSettings() {
        let advanced = makeNavigationSnapshot(isAdvancedExperience: true)
        let casual = makeNavigationSnapshot(isAdvancedExperience: false)
        let model = AppModel(data: advanced)
        model.navigate(to: .analytics)

        model.applyData(casual)

        #expect(model.route == .reports)
        #expect(!model.data.settings.isAdvancedExperience)
    }

    @Test("Casual experience redirects Analytics restored from back or forward history")
    @MainActor
    func casualHistoryFallback() {
        let advanced = makeNavigationSnapshot(isAdvancedExperience: true)
        let casual = makeNavigationSnapshot(isAdvancedExperience: false)
        let model = AppModel(data: advanced)
        model.navigate(to: .analytics)
        model.navigate(to: .update)

        model.applyData(casual)
        model.navigateBack()

        #expect(model.route == .reports)

        let forwardModel = AppModel(data: advanced)
        forwardModel.navigate(to: .analytics)
        forwardModel.navigateBack()
        forwardModel.applyData(casual)
        forwardModel.navigateForward()

        #expect(forwardModel.route == .reports)
    }
}

private func makeNavigationSnapshot(isAdvancedExperience: Bool) -> DesignDataSnapshot {
    let snapshot = DesignDataSnapshot.preview
    let settings = DesignSettingsSnapshot(
        updateBehavior: snapshot.settings.updateBehavior,
        minimumConfidencePercent: snapshot.settings.minimumConfidencePercent,
        releaseYearRestoreThresholdYears: snapshot.settings.releaseYearRestoreThresholdYears,
        artistScope: snapshot.settings.artistScope,
        presentation: .init(isAdvancedExperience: isAdvancedExperience),
        isPostWriteVerificationRequired: snapshot.settings.isPostWriteVerificationRequired,
        discogsState: snapshot.settings.discogsState
    )
    return DesignDataSnapshot(
        health: snapshot.health,
        pipelineActivity: snapshot.pipelineActivity,
        pendingVerification: snapshot.pendingVerification,
        coverage: snapshot.coverage,
        issues: snapshot.issues,
        metrics: snapshot.metrics,
        activity: snapshot.activity,
        artists: snapshot.artists,
        browseScope: snapshot.browseScope,
        changes: snapshot.changes,
        dryRun: snapshot.dryRun,
        changeLog: snapshot.changeLog,
        reportStats: snapshot.reportStats,
        genreDistribution: snapshot.genreDistribution,
        updatesOverTime: snapshot.updatesOverTime,
        yearDistribution: snapshot.yearDistribution,
        runHistory: snapshot.runHistory,
        runHistorySkippedCount: snapshot.runHistorySkippedCount,
        selectedRunReport: snapshot.selectedRunReport,
        settings: settings,
        syncStatusText: snapshot.syncStatusText,
        chrome: snapshot.chrome,
        isPreviewBacked: snapshot.isPreviewBacked
    )
}
