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
