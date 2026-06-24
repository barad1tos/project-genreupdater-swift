// AppDependencies+LibraryServices.swift -- library cache, sync, and maintenance helpers.

import Core
import Foundation
import Services

private let libraryServicesLog = AppLogger.make(category: "dependencies")

private enum AppDependencyServiceError: LocalizedError {
    case librarySyncUnavailable

    var errorDescription: String? {
        switch self {
        case .librarySyncUnavailable:
            "Library sync service is unavailable"
        }
    }
}

extension AppDependencies {
    func refreshTrackIDMapping(
        musicKitTracks: [Track],
        scopedArtists: [String]? = nil,
        mergeExisting: Bool = false
    ) async -> Bool {
        do {
            let mappedCount = try await refreshTrackIDMappingOrThrow(
                musicKitTracks: musicKitTracks,
                scopedArtists: scopedArtists,
                mergeExisting: mergeExisting
            )
            return mappedCount > 0 || musicKitTracks.isEmpty
        } catch {
            libraryServicesLog
                .error("Track ID mapping refresh failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func refreshTrackIDMappingOrThrow(
        musicKitTracks: [Track],
        scopedArtists: [String]? = nil,
        mergeExisting: Bool = false
    ) async throws -> Int {
        guard let mapper = trackIDMapper,
              let bridge = applescriptBridge
        else { return 0 }

        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: musicKitTracks,
            appleScriptClient: bridge,
            batchSize: config.applescript.batchProcessing.idsBatchSize,
            allTrackIDsTimeout: config.applescript.timeouts.fullLibraryFetch,
            tracksByIDsTimeout: config.applescript.timeouts.idsBatchFetch,
            testArtists: scopedArtists ?? config.development.testArtists,
            mergeExisting: mergeExisting
        )
        libraryServicesLog
            .info(
                "Track ID mapping refreshed: \(mappedCount, privacy: .public)/\(musicKitTracks.count, privacy: .public)"
            )
        return mappedCount
    }

    func loadLibrarySnapshot() async -> [Track]? {
        guard let librarySnapshotService else { return nil }

        do {
            return try await librarySnapshotService.loadSnapshot()
        } catch {
            libraryServicesLog
                .warning("Failed to load library snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func persistLoadedLibraryTracks(
        _ tracks: [Track],
        scopedArtists capturedScopedArtists: [String]? = nil
    ) async {
        let scopedArtists = capturedScopedArtists ?? ArtistAllowList.normalized(config.development.testArtists)
        guard !tracks.isEmpty else { return }
        let previousTracks = await loadPreviousIncrementalScopeTracks()
        replacePreviousIncrementalScopeTracks(previousTracks)

        do {
            try await trackStore?.saveTracks(tracks)
        } catch {
            libraryServicesLog.error("Failed to persist loaded tracks: \(error.localizedDescription, privacy: .public)")
        }

        if scopedArtists.isEmpty {
            do {
                _ = try await librarySnapshotService?.saveSnapshot(tracks)
            } catch {
                libraryServicesLog
                    .warning("Failed to save library snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadPreviousIncrementalScopeTracks() async -> [Track] {
        guard let trackStore else { return [] }
        do {
            return try await trackStore.loadAllTracks()
        } catch {
            libraryServicesLog.warning(
                "Failed to load previous incremental scope tracks: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func runMaintenancePreflight() async -> MaintenancePreflightResult? {
        guard let maintenanceCoordinator else { return nil }

        let result = await maintenanceCoordinator.runPreflight()
        maintenancePreflightResult = result

        if let error = result.databaseVerificationError {
            libraryServicesLog.warning("Maintenance preflight database verification failed: \(error, privacy: .public)")
        }
        if result.isPendingVerificationDue {
            libraryServicesLog.info("Maintenance preflight found pending albums due for verification")
        }

        return result
    }

    func synchronizeLibraryNow() async throws -> SyncResult {
        guard let librarySyncService else {
            throw AppDependencyServiceError.librarySyncUnavailable
        }

        return try await librarySyncService.synchronizeNow()
    }

    func refreshAutoSyncStatus() async {
        isAutoSyncRunning = await librarySyncService?.isAutoSyncRunning ?? false
    }

    func setAutoSyncEnabled(_ isEnabled: Bool) async throws {
        guard let librarySyncService else {
            throw AppDependencyServiceError.librarySyncUnavailable
        }

        if isEnabled {
            let interval = Duration.seconds(max(1, config.runtime.incrementalIntervalMinutes) * 60)
            try await librarySyncService.startAutoSync(interval: interval)
        } else {
            await librarySyncService.stopAutoSync()
        }
        isAutoSyncRunning = await librarySyncService.isAutoSyncRunning
    }
}
