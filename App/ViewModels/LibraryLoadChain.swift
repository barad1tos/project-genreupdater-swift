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

        let scopedArtists = LibraryTrackLoader.scopedArtists(from: self)
        let loadStart = ContinuousClock.now
        let cachedTracks = await LibraryTrackLoader.cachedSnapshot(
            from: self,
            scopedArtists: scopedArtists,
            forceRefresh: forceRefresh
        )
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
            cachedTracks: cachedTracks
        )
        guard shouldRepublish else { return }
        await republishActivityProjection()
    }

    private func loadCurrentMirror(
        store: any TrackStateStore,
        token: UInt64,
        scopedArtists: [String],
        loadStart: ContinuousClock.Instant,
        cachedTracks: [Track]?
    ) async -> Bool {
        defer { finishLibraryLoadIfCurrent(token) }

        do {
            let requirement = try mirrorRequirement(scopedArtists: scopedArtists)
            let mirrorLoad = try await LibraryTrackLoader.currentMirror(
                store: store,
                cachedTracks: cachedTracks ?? [],
                requirement: requirement
            )
            await applyCurrentMirrorLoad(
                mirrorLoad,
                token: token,
                scopedArtists: scopedArtists,
                previousTracks: cachedTracks,
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
    ) async {
        guard libraryLoadGate.isCurrent(token) else { return }
        await cacheLibraryLoad(
            mirrorLoad.tracks,
            scopedArtists: scopedArtists,
            isAuthoritative: mirrorLoad.readiness.isReady,
            previousTracks: previousTracks
        )
        guard libraryLoadGate.isCurrent(token) else { return }
        libraryReadiness = mirrorLoad.readiness
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

    private func mirrorRequirement(scopedArtists: [String]) throws -> MirrorRequirement {
        let runtimeConfiguration = try LibrarySyncRuntimeConfiguration(configuration: config)
        let scanDays = runtimeConfiguration.forceMetadataScanIntervalDays
        let maximumAge = scanDays > 0 ? TimeInterval(scanDays) * 86400 : nil
        return MirrorRequirement(
            testArtists: scopedArtists,
            fieldSet: .processingV1,
            maximumMetadataAge: maximumAge
        )
    }

    private func handleLibraryLoadFailure(
        _ error: any Error,
        token: UInt64,
        loadStart: ContinuousClock.Instant
    ) async {
        guard libraryLoadGate.isCurrent(token) else { return }
        await recordLibraryLoad(startedAt: loadStart, outcome: .failed)
        libraryLoadError = LibraryLoadError.make(from: error)
        libraryReadiness = .unavailable(MirrorFailure(
            category: .observation,
            detail: libraryLoadError?.message ?? error.localizedDescription
        ))
        libraryTracks = []
        await applyBrowseTruthForLoad?([], .cachedMirror(scannedAt: nil), token)
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
