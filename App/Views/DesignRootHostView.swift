import Core
import DesignUI
import Services
import SwiftData
import SwiftUI

struct DesignRootHostView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext

    @State private var tracks: [Core.Track] = []
    @State private var metricsSnapshot: PersistedMetricsSnapshot?
    @State private var lastScanDate: Date?
    @State private var isLoading = false
    @State private var loadError: LibraryLoadError?
    @State private var hasStartedInitialLoad = false

    var body: some View {
        RootView(data: snapshot)
            .task {
                await startInitialLoadIfNeeded()
            }
    }

    private var snapshot: DesignDataSnapshot {
        DesignActivitySnapshotAdapter.makeSnapshot(
            from: DesignActivitySnapshotInput(
                tracks: tracks,
                metricsSnapshot: metricsSnapshot,
                lastScanDate: lastScanDate,
                isLoading: isLoading,
                loadError: loadError,
                isDryRun: dependencies.config.runtime.dryRun,
                workflow: .empty,
                pendingVerification: nil,
                isAutoSyncRunning: dependencies.isAutoSyncRunning,
                lastSyncResult: nil,
                now: Date()
            )
        )
    }

    private func startInitialLoadIfNeeded() async {
        guard !hasStartedInitialLoad else { return }
        hasStartedInitialLoad = true
        await loadLibrary()
    }

    private func loadLibrary() async {
        loadError = nil
        loadCachedMetrics()
        await dependencies.refreshAutoSyncStatus()

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: dependencies)
        var hasCachedTracks = false
        let loadStart = ContinuousClock.now

        if let cachedLoad = await LibraryTrackLoader.cachedSnapshot(
            from: dependencies,
            scopedArtists: scopedArtists,
            forceRefresh: false
        ) {
            tracks = cachedLoad.tracks
            hasCachedTracks = cachedLoad.hasTracks
            await recordLibraryLoad(source: "snapshot", count: cachedLoad.tracks.count, startedAt: loadStart)
        }

        guard let reader = LibraryTrackLoader.liveReader(from: dependencies) else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let liveLoad = try await LibraryTrackLoader.liveTracks(
                from: dependencies,
                reader: reader,
                scopedArtists: scopedArtists
            )
            tracks = liveLoad.tracks
            await dependencies.persistLoadedLibraryTracks(liveLoad.tracks, scopedArtists: scopedArtists)
            lastScanDate = liveLoad.scanDate
            metricsSnapshot = upsertDashboardMetricsSnapshot(from: liveLoad.tracks, in: modelContext)
            await recordLibraryLoad(source: "music", count: liveLoad.tracks.count, startedAt: loadStart)
        } catch is CancellationError {
            return
        } catch {
            await dependencies.analyticsService?.trackError("library.load", error: error)
            loadError = LibraryLoadError.make(from: error)
            if !hasCachedTracks {
                tracks = []
            }
        }
    }

    private func loadCachedMetrics() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    private func recordLibraryLoad(
        source: String,
        count: Int,
        startedAt loadStart: ContinuousClock.Instant
    ) async {
        await dependencies.analyticsService?.trackEvent(
            "library.load",
            duration: loadStart.duration(to: .now),
            metadata: [
                "source": source,
                "trackCount": "\(count)",
            ]
        )
    }
}
