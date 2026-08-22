import Core
import Foundation
import Services

/// Library load failures surfaced by the backend load chain.
enum LibraryLoadError: Equatable {
    case permissionDenied
    case restricted
    case failed(String)

    static func make(from error: Error) -> Self {
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
        case let .failed(message):
            message
        }
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
    }

    func loadLibrary(forceRefresh: Bool = false) async {
        let token = libraryLoadGate.begin()
        libraryLoadError = nil
        isLibraryReadyForUpdates = false
        let cachedMetrics = await metricsSnapshotStore?.loadLatest()
        guard libraryLoadGate.isCurrent(token) else { return }
        libraryMetrics = cachedMetrics
        await refreshReportsProjection()
        guard libraryLoadGate.isCurrent(token) else { return }

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: self)
        let loadStart = ContinuousClock.now
        let hasCachedTracks = await applyCachedLibraryLoad(
            token: token,
            scopedArtists: scopedArtists,
            loadStart: loadStart,
            forceRefresh: forceRefresh
        )
        guard libraryLoadGate.isCurrent(token) else { return }

        guard let provider = LibraryTrackLoader.liveProvider(from: self) else {
            finishLibraryLoadIfCurrent(token)
            await republishActivityProjection()
            return
        }

        isLibraryLoading = true
        await republishActivityProjection()

        let shouldRepublish = await loadLiveLibrary(
            provider: provider,
            token: token,
            scopedArtists: scopedArtists,
            loadStart: loadStart,
            hasCachedTracks: hasCachedTracks
        )
        guard shouldRepublish else { return }
        await republishActivityProjection()
    }

    private func loadLiveLibrary(
        provider: LibraryReadProvider,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        hasCachedTracks: Bool
    ) async -> Bool {
        defer { finishLibraryLoadIfCurrent(token) }

        do {
            let liveLoad = try await LibraryTrackLoader.liveTracks(
                provider: provider,
                scopedArtists: scopedArtists
            )
            try await applyLiveLibraryLoad(
                liveLoad,
                token: token,
                scopedArtists: scopedArtists,
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
                hasCachedTracks: hasCachedTracks,
                token: token,
                loadStart: loadStart
            )
        }

        return libraryLoadGate.isCurrent(token)
    }

    private func applyCachedLibraryLoad(
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        forceRefresh: Bool
    ) async -> Bool {
        guard let cachedLoad = await LibraryTrackLoader.cachedSnapshot(
            from: self,
            scopedArtists: scopedArtists,
            forceRefresh: forceRefresh
        ) else { return false }

        guard libraryLoadGate.isCurrent(token) else { return false }
        libraryTracks = cachedLoad.tracks
        await applyBrowseTruthForLoad?(cachedLoad.tracks, .cachedMirror(scannedAt: nil), token)
        onLibraryLoadApplied?(cachedLoad.tracks)
        await recordLibraryLoad(startedAt: loadStart)
        return cachedLoad.hasTracks
    }

    private func applyLiveLibraryLoad(
        _ liveLoad: LibraryLiveTrackLoad,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant
    ) async throws {
        guard libraryLoadGate.isCurrent(token) else { return }
        let reconciledTracks = try await persistLibraryLoad(
            liveLoad.tracks,
            scopedArtists: scopedArtists
        )
        guard libraryLoadGate.isCurrent(token) else { return }
        isLibraryReadyForUpdates = liveLoad.isLibraryReadyForUpdates
        libraryTracks = reconciledTracks
        await applyBrowseTruthForLoad?(reconciledTracks, .liveLibrary(scannedAt: liveLoad.scanDate), token)
        guard libraryLoadGate.isCurrent(token) else { return }
        let upsertedMetrics = await metricsSnapshotStore?.upsert(from: reconciledTracks)
        guard libraryLoadGate.isCurrent(token) else { return }
        lastLibraryScanDate = liveLoad.scanDate
        libraryMetrics = upsertedMetrics
        onLibraryLoadApplied?(reconciledTracks)
        await recordLibraryLoad(startedAt: loadStart)
    }

    private func handleLibraryLoadFailure(
        _ error: any Error,
        hasCachedTracks: Bool,
        token: UInt64,
        loadStart: ContinuousClock.Instant
    ) async {
        guard libraryLoadGate.isCurrent(token) else { return }
        await recordLibraryLoad(startedAt: loadStart, outcome: .failed)
        libraryLoadError = LibraryLoadError.make(from: error)
        if !hasCachedTracks {
            libraryTracks = []
        }
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
