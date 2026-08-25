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

        guard let trackStore else {
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
            hasCachedTracks: hasCachedTracks
        )
        guard shouldRepublish else { return }
        await republishActivityProjection()
    }

    private func loadCurrentMirror(
        store: any TrackStateStore,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        hasCachedTracks: Bool
    ) async -> Bool {
        defer { finishLibraryLoadIfCurrent(token) }

        do {
            let mirrorLoad = try await LibraryTrackLoader.currentMirror(
                store: store,
                scopedArtists: scopedArtists
            )
            if mirrorLoad.tracks.isEmpty,
               !mirrorLoad.isLibraryReadyForUpdates,
               hasCachedTracks {
                await recordLibraryLoad(startedAt: loadStart)
                return libraryLoadGate.isCurrent(token)
            }
            await applyCurrentMirrorLoad(
                mirrorLoad,
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

    private func applyCurrentMirrorLoad(
        _ mirrorLoad: LibraryMirrorTrackLoad,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant
    ) async {
        guard libraryLoadGate.isCurrent(token) else { return }
        await cacheLibraryLoad(
            mirrorLoad.tracks,
            scopedArtists: scopedArtists
        )
        guard libraryLoadGate.isCurrent(token) else { return }
        isLibraryReadyForUpdates = mirrorLoad.isLibraryReadyForUpdates
        libraryTracks = mirrorLoad.tracks
        await applyBrowseTruthForLoad?(mirrorLoad.tracks, .cachedMirror(scannedAt: nil), token)
        guard libraryLoadGate.isCurrent(token) else { return }
        let upsertedMetrics = await metricsSnapshotStore?.upsert(from: mirrorLoad.tracks)
        guard libraryLoadGate.isCurrent(token) else { return }
        lastLibraryScanDate = nil
        libraryMetrics = upsertedMetrics
        onLibraryLoadApplied?(mirrorLoad.tracks)
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
