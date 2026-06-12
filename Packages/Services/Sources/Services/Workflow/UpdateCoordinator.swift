import Core
import Foundation
import OSLog

// MARK: - Update Error

public enum UpdateCoordinatorError: Error, LocalizedError {
    case trackNotEditable(trackID: String)
    case noChangesProduced
    case allTracksFailed(count: Int, errorDescriptions: [String])
    case writeFailed(trackID: String, property: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .trackNotEditable(trackID):
            "Track \(trackID) is not editable"
        case .noChangesProduced:
            "No changes were produced for the given tracks"
        case let .allTracksFailed(count, _):
            "All \(count) tracks failed to update"
        case let .writeFailed(trackID, property, reason):
            "Failed to write \(property) for track \(trackID): \(reason)"
        }
    }
}

extension AlbumTypeDetectionConfig {
    fileprivate func classifyAlbum(_ albumName: String) -> AlbumTypeInfo {
        detectAlbumType(
            albumName,
            specialPatterns: Set(specialPatterns),
            compilationPatterns: Set(compilationPatterns),
            reissuePatterns: Set(reissuePatterns)
        )
    }
}

// MARK: - Update Coordinator

/// Central orchestrator: read → determine → preview → write → log.
///
/// Coordinates all services to update track metadata in Music.app.
/// Supports single-track updates, batch processing, and dry-run previews.
public actor UpdateCoordinator {
    private var apiOrchestrator: APIOrchestrator
    private let scriptBridge: any AppleScriptClient
    private let trackStore: any TrackStateStore
    private let cache: any CacheService
    private let undoCoordinator: UndoCoordinator
    private let idMapper: (any TrackIDMapping)?
    private let genreDeterminator: GenreDeterminator
    private var yearDeterminator: YearDeterminator
    private var runtimeConfiguration: UpdateRuntimeConfiguration
    private let log = Logger(subsystem: "com.genreupdater", category: "UpdateCoordinator")

    public init(
        apiOrchestrator: APIOrchestrator,
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        cache: any CacheService,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)? = nil,
        genreDeterminator: GenreDeterminator,
        yearDeterminator: YearDeterminator = YearDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) {
        self.apiOrchestrator = apiOrchestrator
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.cache = cache
        self.undoCoordinator = undoCoordinator
        self.idMapper = idMapper
        self.genreDeterminator = genreDeterminator
        self.yearDeterminator = yearDeterminator
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func updateRuntimeConfiguration(
        _ runtimeConfiguration: UpdateRuntimeConfiguration,
        yearDeterminator: YearDeterminator,
        apiOrchestrator: APIOrchestrator? = nil
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.yearDeterminator = yearDeterminator
        if let apiOrchestrator {
            self.apiOrchestrator = apiOrchestrator
        }
    }

    // MARK: Single Track

    /// Process a single track: determine changes, optionally write to Music.app.
    ///
    /// - Parameters:
    ///   - track: The track to update
    ///   - albumTracks: Other tracks on the same album (for cross-track scoring)
    ///   - options: Update configuration (genre/year, confidence, auto-accept)
    ///   - dryRun: If true, return proposed changes without writing
    /// - Returns: Proposed changes (written if not dry-run)
    public func updateTrack(
        _ track: Track,
        albumTracks: [Track] = [],
        options: UpdateOptions,
        dryRun: Bool = false
    ) async throws -> [ProposedChange] {
        guard track.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: track.id)
        }

        var proposedChanges: [ProposedChange] = []
        var workingTrack = track

        if let change = Self.determineArtistRenameChange(
            track: workingTrack,
            mappings: runtimeConfiguration.artistRenameMappings
        ) {
            proposedChanges.append(change)
            workingTrack = change.track
        }

        // Genre determination (local — uses existing track genres)
        let canUpdateGenre = runtimeConfiguration.shouldOverrideExistingGenres
            || (workingTrack.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if options.updateGenre, canUpdateGenre {
            let artistTracks = albumTracks.isEmpty ? [workingTrack] : albumTracks
            let genreResult = genreDeterminator.determineDominantGenre(
                artistTracks: artistTracks,
                genreMappings: runtimeConfiguration.genreMappings
            )
            if let newGenre = genreResult.genre, newGenre != workingTrack.genre {
                proposedChanges.append(ProposedChange(
                    track: workingTrack,
                    changeType: .genreUpdate,
                    oldValue: workingTrack.genre,
                    newValue: newGenre,
                    confidence: 80, // Genre from library consensus
                    source: "Library"
                ))
            }
        }

        // Year determination (API-backed)
        if options.updateYear, runtimeConfiguration.isYearLookupEnabled {
            if let change = try await determineYearChange(
                track: workingTrack,
                albumTracks: albumTracks
            ) {
                proposedChanges.append(change)
            }
        }

        proposedChanges.append(contentsOf: Self.determineCleaningChanges(
            track: workingTrack,
            options: options,
            cleaning: runtimeConfiguration.cleaning
        ))

        // Filter by confidence
        let pipeline = ChangePreviewPipeline()
        proposedChanges = pipeline.filter(changes: proposedChanges, minConfidence: options.minConfidence)

        if dryRun {
            return proposedChanges
        }

        // Write accepted changes
        for change in proposedChanges where change.isAccepted {
            try await applyChange(change)
        }

        return proposedChanges
    }

    // MARK: Multi-Track

    /// Update multiple tracks with progress reporting.
    ///
    /// Each track is processed individually. Failures are non-fatal and aggregated.
    /// Change history is recorded in the `UndoCoordinator`.
    /// Returns a `BatchUpdateResult` with both successes and failures.
    public func updateTracks(
        _ tracks: [Track],
        options: UpdateOptions,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> BatchUpdateResult {
        let signpostState = AppSignpost.batchProcessing.beginInterval("updateTracks")
        defer { AppSignpost.batchProcessing.endInterval("updateTracks", signpostState) }

        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        for (index, track) in tracks.enumerated() {
            do {
                _ = try await updateTrack(
                    track,
                    options: options,
                    dryRun: false
                )
            } catch {
                failedTrackIDs.append(track.id)
                errorDescriptions.append(error.localizedDescription)
                log
                    .warning(
                        "Failed to update track \(track.id, privacy: .private): \(error.localizedDescription, privacy: .public)"
                    )
            }

            progressHandler(ProgressUpdate(
                phase: .updating,
                current: index + 1,
                total: tracks.count
            ))
        }

        progressHandler(ProgressUpdate(
            phase: .complete,
            current: tracks.count,
            total: tracks.count
        ))

        // Entries are already recorded in undoCoordinator via applyChange()
        let entries = await undoCoordinator.getHistory()

        if !errorDescriptions.isEmpty, entries.isEmpty {
            throw UpdateCoordinatorError.allTracksFailed(
                count: errorDescriptions.count,
                errorDescriptions: errorDescriptions
            )
        }

        return BatchUpdateResult(
            entries: entries,
            failedTrackIDs: failedTrackIDs,
            errorDescriptions: errorDescriptions
        )
    }

    // MARK: Year Determination

    private func determineYearChange(
        track: Track,
        albumTracks: [Track]
    ) async throws -> ProposedChange? {
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        guard albumTypeInfo.strategy != .markAndSkip else { return nil }

        // Step 1: Check cache
        let cached = await cache.getAlbumYear(
            artist: track.artist,
            album: track.album
        )
        if let cached, Double(cached.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence {
            return yearChangeFromCached(track: track, entry: cached)
        }

        // Step 2: Resolve from local album context when it is strong enough.
        if let localChange = yearChangeFromLocalDetermination(
            track: track,
            albumTracks: albumTracks
        ) {
            return localChange
        }

        // Step 3: Fetch from APIs
        let yearResult = await apiOrchestrator.getAlbumYear(
            artist: track.artist,
            album: track.album,
            currentLibraryYear: track.year,
            earliestTrackAddedYear: earliestAddedYear(albumTracks)
        )

        guard let year = yearResult.year, year != track.year else {
            return nil
        }
        guard Double(yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence else {
            return nil
        }

        // Step 4: Cache the result if it meets the configured persistence threshold.
        if yearResult.confidence >= runtimeConfiguration.minimumConfidenceToCache {
            await cache.storeAlbumYear(
                artist: track.artist,
                album: track.album,
                year: year,
                confidence: yearResult.confidence
            )
        }

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: yearResult.confidence,
            source: yearResult.isDefinitive ? "Definitive" : "API"
        )
    }

    private func yearChangeFromCached(
        track: Track,
        entry: AlbumCacheEntry
    ) -> ProposedChange? {
        guard let year = entry.year, year != track.year else { return nil }
        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: entry.confidence,
            source: "Cache"
        )
    }

    private func yearChangeFromLocalDetermination(
        track: Track,
        albumTracks: [Track]
    ) -> ProposedChange? {
        guard !albumTracks.isEmpty else { return nil }

        let determination = yearDeterminator.determineYear(
            candidates: [],
            track: track,
            albumTracks: albumTracks
        )
        let yearResult = determination.yearResult

        guard Double(yearResult.confidence) >= runtimeConfiguration.minimumYearUpdateConfidence,
              let year = yearResult.year,
              year != track.year
        else {
            return nil
        }

        return ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: track.year.map(String.init),
            newValue: String(year),
            confidence: yearResult.confidence,
            source: determination.source.rawValue.capitalized
        )
    }

    private func earliestAddedYear(_ tracks: [Track]) -> Int? {
        tracks
            .compactMap(\.dateAdded)
            .min()
            .map { Calendar.current.component(.year, from: $0) }
    }

    // MARK: Apply Change

    private func applyChange(_ change: ProposedChange) async throws {
        guard let newValue = change.newValue else { return }

        let property = switch change.changeType {
        case .genreUpdate: "genre"
        case .yearUpdate, .yearRevert: "year"
        case .trackCleaning: "name"
        case .albumCleaning: "album"
        case .artistRename: "artist"
        }

        let writeID = if let idMapper {
            await idMapper.appleScriptID(forMusicKitID: change.track.id) ?? change.track.id
        } else {
            change.track.id
        }

        do {
            try await scriptBridge.updateTrackProperty(
                trackID: writeID,
                property: property,
                value: newValue
            )
        } catch {
            throw UpdateCoordinatorError.writeFailed(
                trackID: change.track.id,
                property: property,
                reason: error.localizedDescription
            )
        }

        // Record for undo
        let logEntry = Self.changeToLogEntry(change)
        await undoCoordinator.recordChange(logEntry)

        // Update track processing state
        try? await trackStore.updateTrackProcessingState(
            id: change.track.id,
            genreUpdated: change.changeType == .genreUpdate ? true : nil,
            yearUpdated: change.changeType == .yearUpdate ? true : nil
        )

        log
            .info(
                "Applied \(change.changeType.rawValue, privacy: .public) to track \(change.track.id, privacy: .private)"
            )
    }
}
