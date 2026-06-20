import Core
import Foundation
import OSLog

// MARK: - Update Error

public enum UpdateCoordinatorError: Error, LocalizedError {
    case trackNotEditable(trackID: String)
    case trackNotProcessable(trackID: String, status: String)
    case noChangesProduced
    case allTracksFailed(count: Int, errorDescriptions: [String])
    case missingAppleScriptID(trackID: String)
    case writeFailed(trackID: String, property: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .trackNotEditable(trackID):
            "Track \(trackID) is not editable"
        case let .trackNotProcessable(trackID, status):
            "Track \(trackID) is not processable in its current status: \(status)"
        case .noChangesProduced:
            "No changes were produced for the given tracks"
        case let .allTracksFailed(count, errorDescriptions):
            Self.allTracksFailedDescription(count: count, errorDescriptions: errorDescriptions)
        case let .missingAppleScriptID(trackID):
            "Cannot write track \(trackID): no AppleScript ID mapping is available"
        case let .writeFailed(trackID, property, reason):
            "Failed to write \(property) for track \(trackID): \(reason)"
        }
    }

    private static func allTracksFailedDescription(count: Int, errorDescriptions: [String]) -> String {
        guard let firstError = errorDescriptions.first, !firstError.isEmpty else {
            return "All \(count) tracks failed to update"
        }
        if count == 1 {
            return firstError
        }
        return "All \(count) tracks failed to update. First error: \(firstError)"
    }
}

extension AlbumTypeDetectionConfig {
    func classifyAlbum(_ albumName: String) -> AlbumTypeInfo {
        detectAlbumType(
            albumName,
            specialPatterns: Set(specialPatterns),
            compilationPatterns: Set(compilationPatterns),
            reissuePatterns: Set(reissuePatterns)
        )
    }
}

// MARK: - Update Coordinator

/// Infrastructure dependencies used by ``UpdateCoordinator``.
public struct UpdateCoordinatorDependencies {
    let apiOrchestrator: APIOrchestrator
    let scriptBridge: any AppleScriptClient
    let trackStore: any TrackStateStore
    let cache: any CacheService
    let undoCoordinator: UndoCoordinator
    let idMapper: (any TrackIDMapping)?
    let librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?

    public init(
        apiOrchestrator: APIOrchestrator,
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        cache: any CacheService,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) {
        self.apiOrchestrator = apiOrchestrator
        self.scriptBridge = scriptBridge
        self.trackStore = trackStore
        self.cache = cache
        self.undoCoordinator = undoCoordinator
        self.idMapper = idMapper
        self.librarySnapshotService = librarySnapshotService
        self.pendingVerificationService = pendingVerificationService
    }
}

/// Central orchestrator: read → determine → preview → write → log.
///
/// Coordinates all services to update track metadata in Music.app.
/// Supports single-track updates, batch processing, and dry-run previews.
public actor UpdateCoordinator {
    var apiOrchestrator: APIOrchestrator
    private let scriptBridge: any AppleScriptClient
    private let trackStore: any TrackStateStore
    let cache: any CacheService
    private let undoCoordinator: UndoCoordinator
    private let idMapper: (any TrackIDMapping)?
    private var librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?
    private let genreDeterminator: GenreDeterminator
    var yearDeterminator: YearDeterminator
    var runtimeConfiguration: UpdateRuntimeConfiguration
    private let log = Logger(subsystem: "com.genreupdater", category: "UpdateCoordinator")

    public init(
        dependencies: UpdateCoordinatorDependencies,
        genreDeterminator: GenreDeterminator,
        yearDeterminator: YearDeterminator = YearDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
    ) {
        apiOrchestrator = dependencies.apiOrchestrator
        scriptBridge = dependencies.scriptBridge
        trackStore = dependencies.trackStore
        cache = dependencies.cache
        undoCoordinator = dependencies.undoCoordinator
        idMapper = dependencies.idMapper
        librarySnapshotService = dependencies.librarySnapshotService
        pendingVerificationService = dependencies.pendingVerificationService
        self.genreDeterminator = genreDeterminator
        self.yearDeterminator = yearDeterminator
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func updateRuntimeConfiguration(
        _ runtimeConfiguration: UpdateRuntimeConfiguration,
        yearDeterminator: YearDeterminator,
        apiOrchestrator: APIOrchestrator? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.yearDeterminator = yearDeterminator
        if let apiOrchestrator {
            self.apiOrchestrator = apiOrchestrator
        }
        if let librarySnapshotService {
            self.librarySnapshotService = librarySnapshotService
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
        guard runtimeConfiguration.allowsTrack(track) else {
            log
                .info(
                    "Skipped track \(track.id, privacy: .private) outside test artist allow-list"
                )
            return []
        }

        let inputTrack = try await trackWithMutationMetadata(track)
        let inputAlbumTracks = await availableTracksWithMutationMetadata(albumTracks)

        guard inputTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: inputTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(inputTrack) else {
            log.info("Skipped unavailable track \(inputTrack.id, privacy: .private)")
            return []
        }

        var proposedChanges: [ProposedChange] = []
        var workingTrack = inputTrack

        if let change = Self.determineArtistRenameChange(
            track: workingTrack,
            mappings: runtimeConfiguration.artistRenameMappings
        ) {
            proposedChanges.append(change)
            workingTrack = change.track
        }

        // Genre determination (local — uses existing track genres)
        let artistTracks = inputAlbumTracks.isEmpty ? [workingTrack] : inputAlbumTracks
        if let change = determineGenreChange(
            track: workingTrack,
            artistTracks: artistTracks,
            options: options
        ) {
            proposedChanges.append(change)
        }

        // Year determination (API-backed)
        if options.updateYear,
           runtimeConfiguration.isYearLookupEnabled,
           let change = try await determineYearChange(
               track: workingTrack,
               albumTracks: inputAlbumTracks
           ) {
            proposedChanges.append(change)
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

    private func determineGenreChange(
        track: Track,
        artistTracks: [Track],
        options: UpdateOptions
    ) -> ProposedChange? {
        let canUpdateGenre = runtimeConfiguration.shouldOverrideExistingGenres
            || (track.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard options.updateGenre, canUpdateGenre else {
            return nil
        }

        let genreResult = genreDeterminator.determineDominantGenre(
            artistTracks: artistTracks,
            genreMappings: runtimeConfiguration.genreMappings
        )
        guard let newGenre = genreResult.genre, newGenre != track.genre else {
            return nil
        }

        return ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: track.genre,
            newValue: newGenre,
            confidence: 80,
            source: "Library"
        )
    }

    private func trackWithMutationMetadata(_ track: Track) async throws -> Track {
        guard let idMapper else {
            return track
        }

        guard let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) else {
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        }

        return enrichedTrack
    }

    private func availableTracksWithMutationMetadata(_ tracks: [Track]) async -> [Track] {
        guard let idMapper else {
            return tracks.filter(Self.isTrackAvailableForProcessing)
        }

        var enrichedTracks: [Track] = []
        enrichedTracks.reserveCapacity(tracks.count)
        for track in tracks {
            if let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track),
               Self.isTrackAvailableForProcessing(enrichedTrack) {
                enrichedTracks.append(enrichedTrack)
            }
        }
        return enrichedTracks
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
        albumTracksProvider: @Sendable (Track) -> [Track] = { _ in [] },
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> BatchUpdateResult {
        let signpostState = AppSignpost.batchProcessing.beginInterval("updateTracks")
        defer { AppSignpost.batchProcessing.endInterval("updateTracks", signpostState) }

        var entries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        for (index, track) in tracks.enumerated() {
            do {
                let trackEntries = try await applyGeneratedAcceptedChanges(
                    for: track,
                    options: options,
                    albumTracksProvider: albumTracksProvider
                )
                entries.append(contentsOf: trackEntries)
            } catch let error as UpdateCoordinatorError {
                if !recordKnownWorkflowFailure(
                    error,
                    fallbackTrackID: track.id,
                    isReviewedChange: false,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                ) {
                    recordUnexpectedWorkflowFailure(
                        trackID: track.id,
                        error: error,
                        failedTrackIDs: &failedTrackIDs,
                        errorDescriptions: &errorDescriptions
                    )
                }
            } catch {
                recordUnexpectedWorkflowFailure(
                    trackID: track.id,
                    error: error,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
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

    private func applyGeneratedAcceptedChanges(
        for track: Track,
        options: UpdateOptions,
        albumTracksProvider: @Sendable (Track) -> [Track]
    ) async throws -> [ChangeLogEntry] {
        let albumTracksWithMutationMetadata = await availableTracksWithMutationMetadata(
            albumTracksProvider(track)
        )
        let changes = try await updateTrack(
            track,
            albumTracks: albumTracksWithMutationMetadata,
            options: options,
            dryRun: true
        )

        var entries: [ChangeLogEntry] = []
        for change in changes where change.isAccepted {
            if let entry = try await applyChange(change) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Apply reviewed proposals exactly as accepted by the user.
    ///
    /// This preserves per-change review decisions: rejected proposals are not
    /// recalculated or reintroduced during the write phase.
    public func applyAcceptedChanges(
        _ changes: [ProposedChange],
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> BatchUpdateResult {
        let accepted = changes.filter(\.isAccepted)
        guard !accepted.isEmpty else {
            throw UpdateCoordinatorError.noChangesProduced
        }

        var entries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        for (index, change) in accepted.enumerated() {
            do {
                if let entry = try await applyChange(change) {
                    entries.append(entry)
                }
            } catch let error as UpdateCoordinatorError {
                if !recordKnownWorkflowFailure(
                    error,
                    fallbackTrackID: change.track.id,
                    isReviewedChange: true,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                ) {
                    recordUnexpectedWorkflowFailure(
                        trackID: change.track.id,
                        error: error,
                        failedTrackIDs: &failedTrackIDs,
                        errorDescriptions: &errorDescriptions
                    )
                }
            } catch {
                recordUnexpectedWorkflowFailure(
                    trackID: change.track.id,
                    error: error,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }

            progressHandler(ProgressUpdate(
                phase: .updating,
                current: index + 1,
                total: accepted.count
            ))
        }

        progressHandler(ProgressUpdate(
            phase: .complete,
            current: accepted.count,
            total: accepted.count
        ))

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

    private func logSkippedMissingAppleScriptID(trackID: String, isReviewedChange: Bool) {
        if isReviewedChange {
            log.info(
                "Skipped reviewed change for track \(trackID, privacy: .private) without AppleScript ID mapping"
            )
        } else {
            log.info("Skipped track \(trackID, privacy: .private) without AppleScript ID mapping")
        }
    }

    private func recordKnownWorkflowFailure(
        _ error: UpdateCoordinatorError,
        fallbackTrackID: String,
        isReviewedChange: Bool,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) -> Bool {
        switch error {
        case let .trackNotEditable(trackID):
            Self.recordFailedTrack(
                id: trackID,
                error: error,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            logNonEditableTrack(trackID: fallbackTrackID, isReviewedChange: isReviewedChange)
        case let .trackNotProcessable(trackID, _):
            Self.recordFailedTrack(
                id: trackID,
                error: error,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            logUnprocessableTrack(trackID: trackID, isReviewedChange: isReviewedChange)
        case let .missingAppleScriptID(trackID):
            Self.recordFailedTrack(
                id: trackID,
                error: error,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            logSkippedMissingAppleScriptID(trackID: trackID, isReviewedChange: isReviewedChange)
        default:
            return false
        }
        return true
    }

    private func logNonEditableTrack(trackID: String, isReviewedChange: Bool) {
        if isReviewedChange {
            log.info("Skipped non-editable reviewed change for track \(trackID, privacy: .private)")
        } else {
            log.info("Skipped non-editable track \(trackID, privacy: .private)")
        }
    }

    private func logUnprocessableTrack(trackID: String, isReviewedChange: Bool) {
        if isReviewedChange {
            log.info("Skipped unprocessable reviewed change for track \(trackID, privacy: .private)")
        } else {
            log.info("Skipped unprocessable track \(trackID, privacy: .private)")
        }
    }

    private func recordUnexpectedWorkflowFailure(
        trackID: String,
        error: any Error,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) {
        Self.recordFailedTrack(
            id: trackID,
            error: error,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        )
        log.warning(
            "Failed workflow operation for track \(trackID, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
    }

    private static func recordFailedTrack(
        id: String,
        error: any Error,
        failedTrackIDs: inout [String],
        errorDescriptions: inout [String]
    ) {
        failedTrackIDs.append(id)
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorDescriptions.append(description)
    }

    // MARK: Apply Change

    @discardableResult
    func applyChange(_ change: ProposedChange) async throws -> ChangeLogEntry? {
        guard runtimeConfiguration.allowsChange(change) else {
            log
                .info(
                    "Skipped change for track \(change.track.id, privacy: .private) outside test artist allow-list"
                )
            return nil
        }

        guard let newValue = change.newValue else { return nil }
        let mutationTrack = try await trackWithMutationMetadata(change.track)
        guard mutationTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: mutationTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(mutationTrack) else {
            throw UpdateCoordinatorError.trackNotProcessable(
                trackID: mutationTrack.id,
                status: mutationTrack.trackStatus ?? "unknown"
            )
        }

        let property = Self.appleScriptProperty(for: change.changeType)

        let writeID: String
        if let idMapper {
            guard let appleScriptID = await idMapper.appleScriptID(forMusicKitID: mutationTrack.id) else {
                throw UpdateCoordinatorError.missingAppleScriptID(trackID: mutationTrack.id)
            }
            writeID = appleScriptID
        } else {
            writeID = mutationTrack.id
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
            yearUpdated: change.changeType == .yearUpdate || change.changeType == .yearRevert ? true : nil
        )
        await invalidateCaches(for: change)

        log
            .info(
                "Applied \(change.changeType.rawValue, privacy: .public) to track \(change.track.id, privacy: .private)"
            )
        return logEntry
    }

    private static func appleScriptProperty(for changeType: ChangeType) -> String {
        switch changeType {
        case .genreUpdate: "genre"
        case .yearUpdate, .yearRevert: "year"
        case .trackCleaning: "name"
        case .albumCleaning: "album"
        case .artistRename: "artist"
        }
    }

    private static func isTrackAvailableForProcessing(_ track: Track) -> Bool {
        track.kind?.isAvailableForProcessing ?? true
    }

    private func invalidateCaches(for change: ProposedChange) async {
        for target in cacheInvalidationTargets(for: change) {
            await cache.invalidateAlbum(artist: target.artist, album: target.album)
            await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
        }
        await librarySnapshotService?.clearSnapshot()
    }

    private func cacheInvalidationTargets(for change: ProposedChange) -> [(artist: String, album: String)] {
        var candidates = [(artist: change.track.artist, album: change.track.album)]

        if let originalArtist = change.track.originalArtist {
            candidates.append((artist: originalArtist, album: change.track.album))
        }
        if change.changeType == .artistRename, let oldArtist = change.oldValue {
            candidates.append((artist: oldArtist, album: change.track.album))
        }
        if change.changeType == .albumCleaning, let newAlbum = change.newValue {
            candidates.append((artist: change.track.artist, album: newAlbum))
        }

        var seenKeys: Set<String> = []
        return candidates.compactMap { candidate in
            let artist = candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = candidate.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !album.isEmpty else { return nil }

            let key = "\(normalizeForMatching(artist))\u{1F}\(normalizeForMatching(album))"
            guard seenKeys.insert(key).inserted else { return nil }
            return (artist: artist, album: album)
        }
    }
}
