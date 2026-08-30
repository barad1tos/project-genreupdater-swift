import Core
import Foundation
import Services

/// Library load failures surfaced by the backend load chain.
enum LibraryLoadError: Error, Equatable, LocalizedError {
    case permissionDenied
    case restricted
    case nonCanonicalMirror(trackID: String)
    case failed(String)

    static func make(from error: Error) -> Self {
        if let libraryLoadError = error as? Self {
            return libraryLoadError
        }
        guard let musicLibraryError = error as? MusicLibraryError else {
            return .failed(error.localizedDescription)
        }

        switch musicLibraryError {
        case .authorizationDenied:
            return .permissionDenied
        case .authorizationRestricted:
            return .restricted
        case .fetchFailed, .musicAppNotAvailable:
            return .failed(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "Music library permission denied"
        case .restricted:
            "Music library access is restricted on this device"
        case let .nonCanonicalMirror(trackID):
            "Stored track \(trackID) lacks canonical Music database identity. Repair the library mirror before loading."
        case let .failed(message):
            message
        }
    }

    var errorDescription: String? {
        message
    }
}

/// Backend-owned library load chain (D1): facts land on the dependency
/// graph and every publish follows from there; the host only triggers
/// (initial task, scope change, queued reload) and renders.
extension AppDependencies {
    /// Invalidate in-flight loads SYNCHRONOUSLY on a scope change:
    /// their facts were snapshotted under the old scope, and a
    /// late-landing apply would out-claim newer truth. The invalidated
    /// chain can no longer own the loading flag, so it resets here.
    func invalidateLibraryLoads() {
        libraryLoadGate.invalidate()
        isLibraryLoading = false
    }

    /// Empties old-scope truth for an ACCEPTED scope change only — a
    /// refused change (active run) keeps the loaded library visible,
    /// matching the pre-chain behavior. A stale load error dies with
    /// the scope that produced it.
    func emptyLibraryTruthForScopeChange() {
        libraryTracks = []
        libraryMetrics = nil
        lastLibraryScanDate = nil
        libraryLoadError = nil
        libraryReadiness = .incomplete(.freshObservationRequired)
    }

    func loadLibrary(forceRefresh: Bool = false) async {
        let token = libraryLoadGate.begin()
        libraryLoadError = nil
        libraryReadiness = .incomplete(.freshObservationRequired)
        let cachedMetrics = await metricsSnapshotStore?.loadLatest()
        guard libraryLoadGate.isCurrent(token) else { return }
        libraryMetrics = cachedMetrics
        await refreshReportsProjection()
        guard libraryLoadGate.isCurrent(token) else { return }

        if forceRefresh || catalogSnapshot == nil {
            await refreshArtistCatalog(republishBrowse: false)
            guard libraryLoadGate.isCurrent(token) else { return }
        }

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: self)
        let loadStart = ContinuousClock.now
        let previousTracks = await LibraryTrackLoader.previousSnapshot(
            from: self,
            scopedArtists: scopedArtists,
            forceRefresh: forceRefresh
        ) ?? libraryTracks
        guard libraryLoadGate.isCurrent(token) else { return }

        guard let trackStore else {
            libraryReadiness = .unavailable(MirrorFailure(
                category: .storage,
                detail: "Track store is unavailable"
            ))
            finishLibraryLoadIfCurrent(token)
            await republishActivityProjection()
            return
        }

        isLibraryLoading = true
        await republishActivityProjection()

        let shouldRepublish = await loadCurrentMirror(
            store: trackStore,
            token: token,
            scopedArtists: scopedArtists,
            loadStart: loadStart,
            previousTracks: previousTracks
        )
        guard shouldRepublish else { return }
        await republishActivityProjection()
    }

    /// Replaces cached presentation facts with the current committed mirror before dependent projections publish.
    func reloadMirrorFacts() async throws {
        let token = libraryLoadGate.begin()
        defer { finishLibraryLoadIfCurrent(token) }
        guard let trackStore else {
            throw LibraryLoadError.failed("Track store is unavailable")
        }

        let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: config)
        let mirrorLoad = try await LibraryTrackLoader.currentMirror(
            store: trackStore,
            requirement: runtimeConfiguration.processingRequirement
        )
        let didApply = await applyCommittedMirrorFacts(
            mirrorLoad,
            token: token
        )
        guard didApply else { throw CancellationError() }
        libraryLoadError = nil
    }

    private func loadCurrentMirror(
        store: any TrackStateStore,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        previousTracks: [Track]
    ) async -> Bool {
        defer { finishLibraryLoadIfCurrent(token) }

        do {
            let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: config)
            let requirement = runtimeConfiguration.processingRequirement
            let mirrorLoad = try await LibraryTrackLoader.currentMirror(
                store: store,
                requirement: requirement
            )
            _ = await applyCurrentMirrorLoad(
                mirrorLoad,
                token: token,
                scopedArtists: scopedArtists,
                previousTracks: previousTracks,
                loadStart: loadStart
            )
        } catch is CancellationError {
            if libraryLoadGate.isCurrent(token) {
                await recordLibraryLoad(startedAt: loadStart, outcome: .cancelled)
            }
            return libraryLoadGate.isCurrent(token)
        } catch {
            await handleLibraryLoadFailure(
                error,
                token: token,
                loadStart: loadStart
            )
        }

        return libraryLoadGate.isCurrent(token)
    }

    private func applyCurrentMirrorLoad(
        _ mirrorLoad: LibraryMirrorTrackLoad,
        token: UInt64,
        scopedArtists: [String],
        previousTracks: [Track]?,
        loadStart: ContinuousClock.Instant
    ) async -> Bool {
        guard libraryLoadGate.isCurrent(token) else { return false }
        await cacheLibraryLoad(
            mirrorLoad.tracks,
            scopedArtists: scopedArtists,
            isAuthoritative: mirrorLoad.readiness.isReady,
            previousTracks: previousTracks
        )
        guard libraryLoadGate.isCurrent(token) else { return false }
        libraryReadiness = mirrorLoad.readiness
        libraryTracks = mirrorLoad.tracks
        await applyBrowseTruth?(
            BrowseProcessingFacts(tracks: mirrorLoad.tracks, readiness: mirrorLoad.readiness),
            token
        )
        guard libraryLoadGate.isCurrent(token) else { return false }
        let upsertedMetrics = await metricsSnapshotStore?.upsert(from: mirrorLoad.tracks)
        guard libraryLoadGate.isCurrent(token) else { return false }
        lastLibraryScanDate = nil
        libraryMetrics = upsertedMetrics
        onMirrorFactsApplied?(mirrorLoad.tracks)
        onLibraryLoadApplied?(mirrorLoad.tracks)
        await recordLibraryLoad(
            startedAt: loadStart,
            outcome: mirrorLoad.readiness.isReady ? .succeeded : .degraded
        )
        return libraryLoadGate.isCurrent(token)
    }

    private func applyCommittedMirrorFacts(
        _ mirrorLoad: LibraryMirrorTrackLoad,
        token: UInt64
    ) async -> Bool {
        guard libraryLoadGate.isCurrent(token) else { return false }
        await applyBrowseTruth?(
            BrowseProcessingFacts(tracks: mirrorLoad.tracks, readiness: mirrorLoad.readiness),
            token
        )
        guard libraryLoadGate.isCurrent(token) else { return false }
        libraryReadiness = mirrorLoad.readiness
        libraryTracks = mirrorLoad.tracks
        libraryMetrics = makeMirrorProjectionMetrics(from: mirrorLoad.tracks)
        onMirrorFactsApplied?(mirrorLoad.tracks)
        return libraryLoadGate.isCurrent(token)
    }

    private func makeMirrorProjectionMetrics(from tracks: [Track]) -> MetricsSnapshotValues? {
        guard let previousValues = libraryMetrics,
              let currentValues = MetricsSnapshotValues.make(from: tracks)
        else { return nil }
        return MetricsSnapshotValues(
            totalTracks: currentValues.totalTracks,
            tracksWithGenre: currentValues.tracksWithGenre,
            tracksWithYear: currentValues.tracksWithYear,
            tracksWithBoth: currentValues.tracksWithBoth,
            tracksNeedingGenre: currentValues.tracksNeedingGenre,
            tracksNeedingYear: currentValues.tracksNeedingYear,
            protectedFileCount: currentValues.protectedFileCount,
            recentlyAdded: currentValues.recentlyAdded,
            timestamp: previousValues.timestamp,
            previousTotalTracks: previousValues.previousTotalTracks,
            previousTracksNeedingGenre: previousValues.previousTracksNeedingGenre,
            previousTracksNeedingYear: previousValues.previousTracksNeedingYear,
            previousRecentlyAdded: previousValues.previousRecentlyAdded
        )
    }

    private func handleLibraryLoadFailure(
        _ error: any Error,
        token: UInt64,
        loadStart: ContinuousClock.Instant
    ) async {
        guard libraryLoadGate.isCurrent(token) else { return }
        await recordLibraryLoad(startedAt: loadStart, outcome: .failed)
        guard libraryLoadGate.isCurrent(token) else { return }
        let loadError = LibraryLoadError.make(from: error)
        let unavailableReadiness = MirrorReadiness.unavailable(MirrorFailure(
            category: .observation,
            detail: loadError.message
        ))
        await applyBrowseTruth?(
            BrowseProcessingFacts(tracks: [], readiness: unavailableReadiness),
            token
        )
        guard libraryLoadGate.isCurrent(token) else { return }
        libraryLoadError = loadError
        libraryReadiness = unavailableReadiness
        libraryTracks = []
        onMirrorFactsApplied?([])
        onLibraryLoadApplied?([])
    }

    private func finishLibraryLoadIfCurrent(_ token: UInt64) {
        if libraryLoadGate.isCurrent(token) {
            isLibraryLoading = false
        }
    }

    private func recordLibraryLoad(
        startedAt loadStart: ContinuousClock.Instant,
        outcome: AnalyticsOutcome = .succeeded
    ) async {
        await analyticsService?.record(
            .libraryLoad,
            duration: loadStart.duration(to: .now),
            outcome: outcome
        )
    }
}
