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
    @State private var changeLogEntries: [Core.ChangeLogEntry] = []
    @State private var lastScanDate: Date?
    @State private var isLoading = false
    @State private var loadError: LibraryLoadError?
    @State private var isSynchronizingLibrary = false
    @State private var syncErrorMessage: String?
    @State private var lastSyncResult: SyncResult?
    @State private var hasStartedInitialLoad = false
    @State private var libraryLoadRequestID = UUID()

    var body: some View {
        RootView(data: snapshot, pipelineSecondaryAction: runManualSync)
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
                // Workflow and verification data stay placeholder-only until the next DesignUI bridge slice wires them.
                workflow: .empty,
                pendingVerification: nil,
                changeLogEntries: changeLogEntries,
                isSynchronizingLibrary: isSynchronizingLibrary,
                syncErrorMessage: syncErrorMessage,
                isLibrarySyncAvailable: dependencies.librarySyncService != nil,
                isAutoSyncRunning: dependencies.isAutoSyncRunning,
                lastSyncResult: lastSyncResult,
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
        let requestID = UUID()
        libraryLoadRequestID = requestID
        loadError = nil
        loadCachedMetrics()
        loadChangeLogEntries()
        await dependencies.refreshAutoSyncStatus()
        guard isCurrentLibraryLoad(requestID) else { return }

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: dependencies)
        let loadStart = ContinuousClock.now
        let hasCachedTracks = await applyCachedLibraryLoad(
            requestID: requestID,
            scopedArtists: scopedArtists,
            loadStart: loadStart
        )
        guard isCurrentLibraryLoad(requestID) else { return }

        guard let reader = LibraryTrackLoader.liveReader(from: dependencies) else {
            finishLibraryLoadIfCurrent(requestID)
            return
        }

        isLoading = true
        defer { finishLibraryLoadIfCurrent(requestID) }

        do {
            let liveLoad = try await LibraryTrackLoader.liveTracks(
                from: dependencies,
                reader: reader,
                scopedArtists: scopedArtists
            )
            await applyLiveLibraryLoad(
                liveLoad,
                requestID: requestID,
                scopedArtists: scopedArtists,
                loadStart: loadStart
            )
        } catch is CancellationError {
            return
        } catch {
            await handleLibraryLoadFailure(error, hasCachedTracks: hasCachedTracks, requestID: requestID)
        }
    }

    private func applyCachedLibraryLoad(
        requestID: UUID,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant
    ) async -> Bool {
        guard let cachedLoad = await LibraryTrackLoader.cachedSnapshot(
            from: dependencies,
            scopedArtists: scopedArtists,
            forceRefresh: false
        ) else { return false }

        guard isCurrentLibraryLoad(requestID) else { return false }
        tracks = cachedLoad.tracks
        await recordLibraryLoad(source: "snapshot", count: cachedLoad.tracks.count, startedAt: loadStart)
        return cachedLoad.hasTracks
    }

    private func applyLiveLibraryLoad(
        _ liveLoad: LibraryLiveTrackLoad,
        requestID: UUID,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant
    ) async {
        guard isCurrentLibraryLoad(requestID) else { return }
        tracks = liveLoad.tracks
        await dependencies.persistLoadedLibraryTracks(liveLoad.tracks, scopedArtists: scopedArtists)
        guard isCurrentLibraryLoad(requestID) else { return }
        lastScanDate = liveLoad.scanDate
        metricsSnapshot = upsertDashboardMetricsSnapshot(from: liveLoad.tracks, in: modelContext)
        await recordLibraryLoad(source: "music", count: liveLoad.tracks.count, startedAt: loadStart)
    }

    private func handleLibraryLoadFailure(
        _ error: any Error,
        hasCachedTracks: Bool,
        requestID: UUID
    ) async {
        guard isCurrentLibraryLoad(requestID) else { return }
        await dependencies.analyticsService?.trackError("library.load", error: error)
        loadError = LibraryLoadError.make(from: error)
        if !hasCachedTracks {
            tracks = []
        }
    }

    private func finishLibraryLoadIfCurrent(_ requestID: UUID) {
        if isCurrentLibraryLoad(requestID) {
            isLoading = false
        }
    }

    private func isCurrentLibraryLoad(_ requestID: UUID) -> Bool {
        libraryLoadRequestID == requestID
    }

    private func loadCachedMetrics() {
        let descriptor = FetchDescriptor<PersistedMetricsSnapshot>()
        metricsSnapshot = try? modelContext.fetch(descriptor).first
    }

    private func loadChangeLogEntries() {
        var descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = DesignActivitySnapshotAdapter.reportEntryLimit
        changeLogEntries = (try? modelContext.fetch(descriptor).map { $0.toChangeLogEntry() }) ?? []
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

    private func runManualSync() {
        guard !isSynchronizingLibrary else { return }

        isSynchronizingLibrary = true
        syncErrorMessage = nil

        Task { @MainActor in
            do {
                let result = try await dependencies.synchronizeLibraryNow()
                lastSyncResult = result
                await loadLibrary()
                isSynchronizingLibrary = false
            } catch {
                lastSyncResult = nil
                syncErrorMessage = error.localizedDescription
                isSynchronizingLibrary = false
            }
        }
    }
}
