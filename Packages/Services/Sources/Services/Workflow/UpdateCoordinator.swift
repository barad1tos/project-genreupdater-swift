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
    let scriptBridge: any AppleScriptClient
    let trackStore: any TrackStateStore
    let cache: any CacheService
    let undoCoordinator: UndoCoordinator
    let idMapper: (any TrackIDMapping)?
    var librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?
    private let genreDeterminator: GenreDeterminator
    var yearDeterminator: YearDeterminator
    var runtimeConfiguration: UpdateRuntimeConfiguration
    let log = Logger(subsystem: "com.genreupdater", category: "UpdateCoordinator")

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
    ///   - artistTracks: All tracks by the same artist (for dominant genre)
    ///   - options: Update configuration (genre/year, confidence, auto-accept)
    ///   - dryRun: If true, return proposed changes without writing
    /// - Returns: Proposed changes (written if not dry-run)
    public func updateTrack(
        _ track: Track,
        albumTracks: [Track] = [],
        artistTracks: [Track] = [],
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

        if track.kind == .prerelease,
           await shouldSkipPrereleaseProcessing(track: track, albumTracks: albumTracks) {
            return []
        }

        let inputTrack = try await trackWithMutationMetadata(track)
        if await shouldSkipPrereleaseProcessing(track: inputTrack, albumTracks: albumTracks) {
            return []
        }

        let inputAlbumTracks = await availableTracksWithMutationMetadata(albumTracks)
        let inputArtistTracks = await availableTracksWithMutationMetadata(artistTracks)

        guard inputTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: inputTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(inputTrack) else {
            log.info("Skipped unavailable track \(inputTrack.id, privacy: .private)")
            return []
        }

        let candidateChanges = try await proposedChanges(
            for: inputTrack,
            albumTracks: inputAlbumTracks,
            artistTracks: inputArtistTracks,
            options: options
        )
        let proposedChanges = ChangePreviewPipeline().filter(
            changes: candidateChanges,
            minConfidence: options.minConfidence
        )

        if dryRun {
            return proposedChanges
        }

        // Write accepted changes
        for change in proposedChanges where change.isAccepted {
            try await applyChange(change)
        }

        return proposedChanges
    }

    private func proposedChanges(
        for track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) async throws -> [ProposedChange] {
        var proposedChanges: [ProposedChange] = []
        var workingTrack = track

        let cleaningChanges = Self.determineCleaningChanges(
            track: workingTrack,
            options: options,
            cleaning: runtimeConfiguration.cleaning
        )
        proposedChanges.append(contentsOf: cleaningChanges)
        workingTrack = Self.cleanedTrack(from: workingTrack, applying: cleaningChanges)

        if let change = Self.determineArtistRenameChange(
            track: workingTrack,
            mappings: runtimeConfiguration.artistRenameMappings
        ) {
            proposedChanges.append(change)
            workingTrack = change.track
        }

        let genreContextTracks = Self.genreContextTracks(
            track: workingTrack,
            artistTracks: artistTracks,
            albumTracks: albumTracks
        )
        if let change = determineGenreChange(
            track: workingTrack,
            artistTracks: genreContextTracks,
            options: options
        ) {
            proposedChanges.append(change)
        }

        if options.updateYear,
           runtimeConfiguration.isYearLookupEnabled,
           let change = try await determineYearChange(
               track: workingTrack,
               albumTracks: albumTracks,
               forceYearLookup: options.forceYearLookup
           ) {
            proposedChanges.append(change)
        }

        return proposedChanges
    }

    private static func cleanedTrack(
        from track: Track,
        applying changes: [ProposedChange]
    ) -> Track {
        guard !changes.isEmpty else { return track }

        var cleanedTrack = track
        for change in changes {
            switch change.changeType {
            case .trackCleaning:
                if let cleanedName = change.newValue {
                    cleanedTrack.name = cleanedName
                }
            case .albumCleaning:
                if let cleanedAlbum = change.newValue {
                    cleanedTrack.album = cleanedAlbum
                }
            default:
                continue
            }
        }
        return cleanedTrack
    }

    private func determineGenreChange(
        track: Track,
        artistTracks: [Track],
        options: UpdateOptions
    ) -> ProposedChange? {
        let canRepairExistingGenre = runtimeConfiguration.shouldOverrideExistingGenres
            || options.repairExistingGenreMismatches
        let canUpdateGenre = canRepairExistingGenre
            || Self.isMissingGenre(track.genre)
        guard options.updateGenre, canUpdateGenre else {
            return nil
        }

        let genreResult = genreDeterminator.determineDominantGenre(
            artistTracks: Self.genreSourceTracks(artistTracks),
            genreMappings: runtimeConfiguration.genreMappings
        )
        guard let newGenre = genreResult.genre,
              Self.hasGenreValueChanged(currentGenre: track.genre, newGenre: newGenre)
        else {
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

    private static func isMissingGenre(_ genre: String?) -> Bool {
        guard let genre else { return true }
        let normalizedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedGenre.isEmpty || normalizedGenre == "unknown"
    }

    private static func genreSourceTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { !isMissingGenre($0.genre) }
    }

    private static func hasGenreValueChanged(currentGenre: String?, newGenre: String) -> Bool {
        let normalizedCurrentGenre = currentGenre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedNewGenre = newGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedCurrentGenre != normalizedNewGenre
    }

    private func shouldSkipPrereleaseProcessing(track: Track, albumTracks: [Track]) async -> Bool {
        guard runtimeConfiguration.skipPrerelease else {
            return false
        }

        let contextTracks = albumContextTracks(track: track, albumTracks: albumTracks)
        let prereleaseCount = contextTracks.count(where: { $0.kind == .prerelease })
        guard prereleaseCount > 0 else {
            return false
        }

        let editableCount = contextTracks.count(where: { $0.canEdit })

        switch runtimeConfiguration.prereleaseHandling {
        case .skipAll:
            return true
        case .markOnly:
            await markPrereleaseAlbum(
                track: track,
                metadata: [
                    "editable_count": String(editableCount),
                    "mode": "mark_only",
                    "prerelease_count": String(prereleaseCount),
                    "track_count": String(contextTracks.count),
                ]
            )
            return true
        case .processEditable:
            var metadata = [
                "prerelease_count": String(prereleaseCount),
                "track_count": String(contextTracks.count),
            ]
            if editableCount == 0 {
                metadata["all_prerelease"] = "true"
                await markPrereleaseAlbum(track: track, metadata: metadata)
                return true
            }
            metadata["editable_count"] = String(editableCount)
            metadata["mixed_album"] = "true"
            await markPrereleaseAlbum(track: track, metadata: metadata)
            return !track.canEdit
        }
    }

    func albumContextTracks(track: Track, albumTracks: [Track]) -> [Track] {
        albumTracks.contains { $0.id == track.id } ? albumTracks : albumTracks + [track]
    }

    /// Returns album-level context for each track after writable metadata enrichment.
    ///
    /// MusicKit tracks can miss AppleScript-only fields such as `albumArtist`, persistent IDs, and write
    /// eligibility. This helper refreshes that metadata first, filters non-processable tracks, and then groups
    /// by `AlbumIdentity` so preview and live workflow paths use the same album context.
    public func albumContextTracksByTrackID(for tracks: [Track]) async -> [String: [Track]] {
        let contextTracks = await availableTracksWithMutationMetadata(tracks)
        return Self.albumTracksByTrackID(for: contextTracks)
    }

    private static func genreContextTracks(
        track: Track,
        artistTracks: [Track],
        albumTracks: [Track]
    ) -> [Track] {
        let availableArtistTracks = artistTracks.filter(isTrackAvailableForProcessing)
        if !availableArtistTracks.isEmpty {
            return tracks(availableArtistTracks, containing: track)
        }

        if !albumTracks.isEmpty {
            return tracks(albumTracks, containing: track)
        }

        return [track]
    }

    private static func tracks(_ tracks: [Track], containing track: Track) -> [Track] {
        tracks.contains { $0.id == track.id } ? tracks : tracks + [track]
    }

    private func markPrereleaseAlbum(
        track: Track,
        metadata: [String: String]
    ) async {
        let identity = track.albumIdentity
        await pendingVerificationService?.markForVerification(
            artist: identity.artist,
            album: identity.album,
            reason: "prerelease",
            metadata: metadata,
            recheckDays: runtimeConfiguration.prereleaseRecheckDays
        )
    }

    func trackWithMutationMetadata(_ track: Track) async throws -> Track {
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
        albumTracksProvider: (@Sendable (Track) -> [Track])? = nil,
        artistTracksProvider: (@Sendable (Track) -> [Track])? = nil,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> BatchUpdateResult {
        let signpostState = AppSignpost.batchProcessing.beginInterval("updateTracks")
        defer { AppSignpost.batchProcessing.endInterval("updateTracks", signpostState) }

        var entries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []
        let trackProviders = await makeUpdateTrackProviders(
            tracks: tracks,
            albumTracksProvider: albumTracksProvider,
            artistTracksProvider: artistTracksProvider
        )

        for (index, track) in tracks.enumerated() {
            do {
                let trackEntries = try await applyGeneratedAcceptedChanges(
                    for: track,
                    options: options,
                    albumTracksProvider: trackProviders.album,
                    artistTracksProvider: trackProviders.artist
                )
                entries.append(contentsOf: trackEntries)
            } catch is CancellationError {
                throw CancellationError()
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

            Self.reportUpdateProgress(index: index, total: tracks.count, progressHandler: progressHandler)
        }

        Self.reportUpdateComplete(total: tracks.count, progressHandler: progressHandler)

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

    private func makeUpdateTrackProviders(
        tracks: [Track],
        albumTracksProvider: (@Sendable (Track) -> [Track])?,
        artistTracksProvider: (@Sendable (Track) -> [Track])?
    ) async -> (album: @Sendable (Track) -> [Track], artist: @Sendable (Track) -> [Track]) {
        let contextTracks = if albumTracksProvider == nil || artistTracksProvider == nil {
            await availableTracksWithMutationMetadata(tracks)
        } else {
            tracks
        }
        let resolvedAlbumTracksProvider = albumTracksProvider ?? Self.albumTracksProvider(
            Self.albumTracksByTrackID(for: contextTracks)
        )
        let resolvedArtistTracksProvider = artistTracksProvider ?? Self.artistTracksProvider(
            Self.artistTracksByTrackID(for: contextTracks)
        )
        return (resolvedAlbumTracksProvider, resolvedArtistTracksProvider)
    }

    private static func reportUpdateProgress(
        index: Int,
        total: Int,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) {
        progressHandler(ProgressUpdate(
            phase: .updating,
            current: index + 1,
            total: total
        ))
    }

    private static func reportUpdateComplete(
        total: Int,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) {
        progressHandler(ProgressUpdate(
            phase: .complete,
            current: total,
            total: total
        ))
    }

    private func applyGeneratedAcceptedChanges(
        for track: Track,
        options: UpdateOptions,
        albumTracksProvider: @Sendable (Track) -> [Track],
        artistTracksProvider: @Sendable (Track) -> [Track]
    ) async throws -> [ChangeLogEntry] {
        let albumTracksWithMutationMetadata = await availableTracksWithMutationMetadata(
            albumTracksProvider(track)
        )
        let artistTracks = artistTracksProvider(track).filter(Self.isTrackAvailableForProcessing)
        let changes = try await updateTrack(
            track,
            albumTracks: albumTracksWithMutationMetadata,
            artistTracks: artistTracks,
            options: options,
            dryRun: true
        )

        let acceptedChanges = changes.filter(\.isAccepted)
        if let entries = try await applyChangesAsBatchIfPossible(acceptedChanges) {
            return entries
        }

        var entries: [ChangeLogEntry] = []
        for change in acceptedChanges {
            if let entry = try await applyChange(change) {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func albumTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        let tracksByAlbum = Dictionary(grouping: tracks.filter(isTrackAvailableForProcessing)) { track in
            AlbumIdentity.key(for: track)
        }
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, tracksByAlbum[AlbumIdentity.key(for: track)] ?? [])
        })
    }

    private static func albumTracksProvider(
        _ albumTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) -> [Track] {
        { track in
            albumTracksByTrackID[track.id] ?? []
        }
    }

    private static func artistTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        let tracksByArtist = Dictionary(grouping: tracks.filter(isTrackAvailableForProcessing)) {
            normalizeForMatching($0.effectiveArtist)
        }
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            (track.id, tracksByArtist[normalizeForMatching(track.effectiveArtist)] ?? [])
        })
    }

    private static func artistTracksProvider(
        _ artistTracksByTrackID: [String: [Track]]
    ) -> @Sendable (Track) -> [Track] {
        { track in
            artistTracksByTrackID[track.id] ?? []
        }
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

        var index = 0
        while index < accepted.count {
            let changeGroup = reviewedChangeGroup(in: accepted, startingAt: index)
            let groupEntries = try await applyReviewedChangeGroup(
                changeGroup,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            entries.append(contentsOf: groupEntries)

            for progressOffset in changeGroup.indices {
                progressHandler(ProgressUpdate(
                    phase: .updating,
                    current: index + progressOffset + 1,
                    total: accepted.count
                ))
            }
            index += changeGroup.count
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

    func recordKnownWorkflowFailure(
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

    func recordUnexpectedWorkflowFailure(
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
}
