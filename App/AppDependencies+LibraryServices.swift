// AppDependencies+LibraryServices.swift -- library cache, sync, and maintenance helpers.

import Core
import Foundation
import Services

private let libraryServicesLog = AppLogger.make(category: "dependencies")

private enum AppDependencyServiceError: LocalizedError {
    case librarySyncUnavailable
    case pendingVerificationUnavailable

    var errorDescription: String? {
        switch self {
        case .librarySyncUnavailable:
            "Library sync service is unavailable"
        case .pendingVerificationUnavailable:
            "Pending verification service is unavailable"
        }
    }
}

struct ProblematicAlbumsReportExport {
    let albumCount: Int
    let reportURL: URL
}

extension AppDependencies {
    func refreshTrackIDMapping(musicKitTracks: [Track]) async {
        guard let mapper = trackIDMapper,
              let bridge = applescriptBridge
        else { return }

        do {
            let mappedCount = try await mapper.refreshMapping(
                musicKitTracks: musicKitTracks,
                appleScriptClient: bridge,
                batchSize: config.applescript.batchProcessing.idsBatchSize,
                allTrackIDsTimeout: config.applescript.timeouts.fullLibraryFetch,
                tracksByIDsTimeout: config.applescript.timeouts.idsBatchFetch,
                testArtists: config.development.testArtists
            )
            libraryServicesLog
                .info(
                    "Track ID mapping refreshed: \(mappedCount, privacy: .public)/\(musicKitTracks.count, privacy: .public)"
                )
        } catch {
            libraryServicesLog
                .error("Track ID mapping refresh failed: \(error.localizedDescription, privacy: .public)")
        }
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

    func persistLoadedLibraryTracks(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }

        do {
            try await trackStore?.saveTracks(tracks)
        } catch {
            libraryServicesLog.error("Failed to persist loaded tracks: \(error.localizedDescription, privacy: .public)")
        }

        do {
            _ = try await librarySnapshotService?.saveSnapshot(tracks)
        } catch {
            libraryServicesLog
                .warning("Failed to save library snapshot: \(error.localizedDescription, privacy: .public)")
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

    func exportProblematicAlbumsReport() async throws -> ProblematicAlbumsReportExport {
        guard let pendingVerificationService else {
            throw AppDependencyServiceError.pendingVerificationUnavailable
        }

        let logsDirectory = Self.resolvedURL(path: config.paths.effectiveLogsBaseDirectory)
        let reportURL = Self.resolvedURL(
            path: config.reporting.problematicAlbumsPath,
            relativeTo: logsDirectory
        )
        let minAttempts = max(1, Int(config.reporting.minAttemptsForReport.rounded()))
        let count = try await pendingVerificationService.generateProblematicAlbumsReport(
            minAttempts: minAttempts,
            reportURL: reportURL
        )

        return ProblematicAlbumsReportExport(albumCount: count, reportURL: reportURL)
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

    private static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = defaultDirectory().path
        var expandedPath = path
            .replacingOccurrences(of: "${APP_SUPPORT}", with: appSupport)
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expandedPath == "~" {
            expandedPath = home
        } else if expandedPath.hasPrefix("~/") {
            expandedPath = home + String(expandedPath.dropFirst())
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }

        return (baseURL ?? defaultDirectory()).appendingPathComponent(expandedPath)
    }

    private static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
