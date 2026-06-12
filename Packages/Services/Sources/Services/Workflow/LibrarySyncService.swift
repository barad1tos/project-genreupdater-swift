import Core
import Foundation
import OSLog

// MARK: - Sync Error

public enum LibrarySyncError: Error, LocalizedError {
    case featureNotAvailable(feature: AppFeature, currentTier: Tier)
    case syncAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case let .featureNotAvailable(feature, tier):
            "\(feature.rawValue) requires a higher tier than \(tier)"
        case .syncAlreadyRunning:
            "Auto-sync is already running"
        }
    }
}

// MARK: - Sync Result

/// Result of comparing the current library state against the last known state.
public struct SyncResult: Sendable {
    public let newTracks: [Track]
    public let modifiedTracks: [Track]
    public let removedTrackIDs: [String]

    public var hasChanges: Bool {
        !newTracks.isEmpty || !modifiedTracks.isEmpty || !removedTrackIDs.isEmpty
    }

    public init(
        newTracks: [Track] = [],
        modifiedTracks: [Track] = [],
        removedTrackIDs: [String] = []
    ) {
        self.newTracks = newTracks
        self.modifiedTracks = modifiedTracks
        self.removedTrackIDs = removedTrackIDs
    }
}

// MARK: - Library Sync Service

/// Runtime settings used while reading library state through AppleScript.
public struct LibrarySyncRuntimeConfiguration: Sendable, Equatable {
    public let idsBatchSize: Int
    public let fullLibraryFetchTimeout: Duration
    public let idsBatchFetchTimeout: Duration

    public init(
        idsBatchSize: Int = BatchProcessingConfig().idsBatchSize,
        fullLibraryFetchTimeout: Duration = AppleScriptTimeouts().fullLibraryFetch,
        idsBatchFetchTimeout: Duration = AppleScriptTimeouts().idsBatchFetch
    ) {
        self.idsBatchSize = max(1, idsBatchSize)
        self.fullLibraryFetchTimeout = fullLibraryFetchTimeout
        self.idsBatchFetchTimeout = idsBatchFetchTimeout
    }

    public init(configuration: AppConfiguration) {
        self.init(
            idsBatchSize: configuration.applescript.batchProcessing.idsBatchSize,
            fullLibraryFetchTimeout: configuration.applescript.timeouts.fullLibraryFetch,
            idsBatchFetchTimeout: configuration.applescript.timeouts.idsBatchFetch
        )
    }
}

/// Detects library changes and suggests updates for new/modified tracks.
///
/// Manual sync (all tiers): compare current library IDs against stored state.
/// Auto-sync (Pro only): periodic background polling with configurable interval.
public actor LibrarySyncService {
    private let scriptBridge: any AppleScriptClient
    private let trackStore: any TrackStateStore
    private let featureGate: FeatureGate
    private var runtimeConfiguration: LibrarySyncRuntimeConfiguration
    private var autoSyncTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.genreupdater", category: "LibrarySyncService")

    public init(
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        featureGate: FeatureGate,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration()
    ) {
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.featureGate = featureGate
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func updateRuntimeConfiguration(_ runtimeConfiguration: LibrarySyncRuntimeConfiguration) {
        self.runtimeConfiguration = runtimeConfiguration
    }

    // MARK: Manual Sync

    /// Detect changes between the current Music.app library and stored state.
    public func detectChanges() async throws -> SyncResult {
        let libraryIDs = try await scriptBridge.fetchAllTrackIDs(
            timeout: runtimeConfiguration.fullLibraryFetchTimeout
        )
        let storedTracks = try await trackStore.loadAllTracks()
        let storedByID = Dictionary(uniqueKeysWithValues: storedTracks.map { ($0.id, $0) })
        let storedIDSet = Set(storedByID.keys)
        let libraryIDSet = Set(libraryIDs)

        // New tracks: in library but not in store
        let newIDs = libraryIDSet.subtracting(storedIDSet)

        // Removed tracks: in store but not in library
        let removedIDs = storedIDSet.subtracting(libraryIDSet).sorted()

        // Fetch full metadata for new tracks
        let newTracks: [Track] = if !newIDs.isEmpty {
            try await scriptBridge.fetchTracksByIDs(
                Array(newIDs),
                batchSize: runtimeConfiguration.idsBatchSize,
                timeout: runtimeConfiguration.idsBatchFetchTimeout
            )
        } else {
            []
        }

        // Modified tracks: exist in both, but need refresh to detect changes.
        // We fetch current state for tracks that exist in both sets,
        // then compare lastModified timestamps.
        let commonIDs = libraryIDSet.intersection(storedIDSet)
        var modifiedTracks: [Track] = []

        if !commonIDs.isEmpty {
            let currentTracks = try await scriptBridge.fetchTracksByIDs(
                Array(commonIDs),
                batchSize: runtimeConfiguration.idsBatchSize,
                timeout: runtimeConfiguration.idsBatchFetchTimeout
            )
            for current in currentTracks {
                guard let stored = storedByID[current.id] else { continue }
                if hasTrackChanged(current: current, stored: stored) {
                    modifiedTracks.append(current)
                }
            }
        }

        let result = SyncResult(
            newTracks: newTracks,
            modifiedTracks: modifiedTracks,
            removedTrackIDs: removedIDs
        )

        log
            .info(
                "Sync detected: \(result.newTracks.count, privacy: .public) new, \(result.modifiedTracks.count, privacy: .public) modified, \(result.removedTrackIDs.count, privacy: .public) removed"
            )
        return result
    }

    // MARK: Auto Sync

    /// Start periodic background sync (Pro only).
    public func startAutoSync(interval: Duration) async throws {
        guard await featureGate.canAccess(.autoSync) else {
            throw await LibrarySyncError.featureNotAvailable(
                feature: .autoSync,
                currentTier: featureGate.currentTier
            )
        }
        guard autoSyncTask == nil else {
            throw LibrarySyncError.syncAlreadyRunning
        }

        log.info("Starting auto-sync with interval \(interval, privacy: .public)")
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard let self else { break }
                do {
                    let result = try await self.detectChanges()
                    if result.hasChanges {
                        self.log
                            .info(
                                "Auto-sync found changes: \(result.newTracks.count, privacy: .public) new, \(result.modifiedTracks.count, privacy: .public) modified"
                            )
                    }
                } catch {
                    self.log.error("Auto-sync error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Stop the background auto-sync loop.
    public func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        log.info("Auto-sync stopped")
    }

    /// Whether auto-sync is currently running.
    public var isAutoSyncRunning: Bool {
        guard let task = autoSyncTask else { return false }
        return !task.isCancelled
    }

    // MARK: Helpers

    private func hasTrackChanged(current: Track, stored: Track) -> Bool {
        if let currentMod = current.lastModified, let storedMod = stored.lastModified {
            return currentMod > storedMod
        }
        // If no lastModified, compare core fields
        return current.genre != stored.genre
            || current.year != stored.year
            || current.name != stored.name
            || current.album != stored.album
            || current.artist != stored.artist
    }
}
