import Core
import Foundation
import OSLog

enum PendingAlbumReason: String, Sendable {
    case prerelease
    case suspiciousAlbum = "suspicious_album_name"
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

/// Central orchestrator: read → determine → preview → write → log.
///
/// Coordinates all services to update track metadata in Music.app.
/// Supports single-track updates, batch processing, and dry-run previews.
public actor UpdateCoordinator {
    var apiOrchestrator: APIOrchestrator
    let writer: (any MusicAppMutating & MusicAppVerifying)?
    let trackStore: any TrackStateStore
    let cache: any CacheService
    let undoCoordinator: UndoCoordinator
    let idMapper: (any TrackIDMapping)?
    var librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?
    let analytics: (any AnalyticsService)?
    let genreDeterminator: GenreDeterminator
    var yearDeterminator: YearDeterminator
    var runtimeConfiguration: UpdateRuntimeConfiguration
    let decisionDate: @Sendable () -> Date
    /// The run whose change-log entries this coordinator currently produces;
    /// nil outside a run-attributed write (entries then stay unattributed).
    private var runAttributionID: RunID?
    let log = Logger(subsystem: "com.genreupdater", category: "UpdateCoordinator")

    public init(
        dependencies: UpdateDependencies,
        genreDeterminator: GenreDeterminator,
        yearDeterminator: YearDeterminator = YearDeterminator(),
        runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
        decisionDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        apiOrchestrator = dependencies.apiOrchestrator
        writer = dependencies.writer
        trackStore = dependencies.stores.trackStore
        cache = dependencies.stores.cache
        undoCoordinator = dependencies.undoCoordinator
        idMapper = dependencies.idMapper
        librarySnapshotService = dependencies.librarySnapshotService
        pendingVerificationService = dependencies.pendingVerificationService
        analytics = dependencies.analytics
        self.genreDeterminator = genreDeterminator
        self.yearDeterminator = yearDeterminator
        self.runtimeConfiguration = runtimeConfiguration
        self.decisionDate = decisionDate
    }

    public func setRunAttribution(_ runID: RunID?) {
        runAttributionID = runID
    }

    func mutationAccess() throws -> any MusicAppMutating & MusicAppVerifying {
        guard let writer else {
            throw UpdateCoordinatorError.mutationUnavailable
        }
        return writer
    }

    /// Test seam: the attribution is otherwise observable only through
    /// persisted entries, which need a landed write to exist.
    func runAttribution() -> RunID? {
        runAttributionID
    }

    /// Stamps the active run onto a freshly built change-log entry; entries
    /// already carrying an attribution keep it. Only entries that reach the
    /// change-log store are stamped — no-op entries feed summary counts and
    /// are never persisted.
    func attributed(_ entry: ChangeLogEntry) -> ChangeLogEntry {
        guard entry.runID == nil, let runAttributionID else { return entry }
        var stamped = entry
        stamped.runID = runAttributionID.rawValue
        return stamped
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

    /// Determines changes for one track and optionally writes them to Music.app.
    ///
    /// Reuse `yearRunScope` to share one album-level API decision and apply its cache or pending effects once.
    public func updateTrack(
        _ track: Track,
        albumTracks: [Track] = [],
        artistTracks: [Track] = [],
        options: UpdateOptions,
        pass: UpdatePass = .standard,
        dryRun: Bool = false,
        yearRunScope: YearRunScope? = nil
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

        let inputTrack = try await trackWithMutationMetadata(
            track,
            requiresMutationMetadata: !dryRun
        )
        if await shouldSkipPrereleaseProcessing(track: inputTrack, albumTracks: albumTracks) {
            return []
        }

        let inputAlbumTracks = await availableTracksWithMutationMetadata(
            albumTracks,
            requiresMutationMetadata: !dryRun
        )
        let inputArtistTracks = await enrichTracks(
            artistTracks,
            requiresMutationMetadata: false
        )

        guard inputTrack.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: inputTrack.id)
        }
        guard Self.isTrackAvailableForProcessing(inputTrack) else {
            log.info("Skipped unavailable track \(inputTrack.id, privacy: .private)")
            return []
        }

        let candidateChanges = try await proposedChanges(
            for: inputTrack,
            trackContext: (album: inputAlbumTracks, artist: inputArtistTracks),
            options: options,
            pass: pass,
            yearRunScope: yearRunScope
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
            try await applyChange(change, isReviewedChange: false)
        }

        return proposedChanges
    }

    private func proposedChanges(
        for track: Track,
        trackContext: (album: [Track], artist: [Track]),
        options: UpdateOptions,
        pass: UpdatePass,
        yearRunScope: YearRunScope?
    ) async throws -> [ProposedChange] {
        var proposedChanges: [ProposedChange] = []
        let albumTypeInfo = runtimeConfiguration.albumTypeDetection.classifyAlbum(track.album)
        let cleaningOutcome = pass.includesStandardMetadata
            ? Self.cleaningOutcome(
                policyTrack: track,
                proposalTrack: track,
                options: options,
                cleaning: runtimeConfiguration.cleaning
            )
            : (track: track, changes: [])
        proposedChanges.append(contentsOf: cleaningOutcome.changes)
        let artistRenameChange = pass.includesStandardMetadata
            ? Self.determineArtistRenameChange(
                track: track,
                mappings: runtimeConfiguration.artistRenameMappings
            )
            : nil
        if let change = artistRenameChange {
            proposedChanges.append(change)
        }
        let proposalTrack = artistRenameChange?.track ?? track
        var decisionTrack = cleaningOutcome.track
        (decisionTrack.artist, decisionTrack.originalArtist, decisionTrack.albumArtist) =
            (proposalTrack.artist, proposalTrack.originalArtist, proposalTrack.albumArtist)
        let genreContextTracks = Self.genreContextTracks(
            track: decisionTrack,
            artistTracks: trackContext.artist,
            albumTracks: trackContext.album
        )
        if pass.includesStandardMetadata,
           let change = await determineGenreChange(
               track: decisionTrack,
               artistTracks: genreContextTracks,
               options: options
           ) {
            proposedChanges.append(Self.change(change, usingTrack: proposalTrack))
        }
        if pass.includesYear,
           options.updateYear,
           runtimeConfiguration.isYearLookupEnabled,
           let change = try await determineYearChange(
               track: decisionTrack,
               safetyTrack: track,
               albumTracks: trackContext.album,
               forceYearLookup: options.forceYearLookup,
               albumTypeInfo: albumTypeInfo,
               queryAlbum: detectSearchStrategy(
                   artist: AlbumIdentity.groupingArtist(for: proposalTrack),
                   album: proposalTrack.album,
                   soundtrackPatterns: runtimeConfiguration.albumTypeDetection.soundtrackPatterns,
                   variousArtistsNames: runtimeConfiguration.albumTypeDetection.variousArtistsNames
               ).strategy == .soundtrack ? proposalTrack.album : decisionTrack.album,
               missingYearThreshold: Double(options.minConfidence),
               yearRunScope: yearRunScope
           ) {
            proposedChanges.append(Self.change(change, usingTrack: proposalTrack))
        }
        return proposedChanges
    }

    private static func change(_ change: ProposedChange, usingTrack track: Track) -> ProposedChange {
        ProposedChange(
            id: change.id,
            track: track,
            changeType: change.changeType,
            oldValue: change.oldValue,
            newValue: change.newValue,
            confidence: change.confidence,
            source: change.source,
            isAccepted: change.isAccepted
        )
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

    /// Returns album-level context after enriching MusicKit tracks with AppleScript-only fields such as
    /// `albumArtist`, database IDs, and write
    /// eligibility. This helper refreshes that metadata first, filters non-processable tracks, and then groups
    /// by `AlbumIdentity` so preview and live workflow paths use the same album context.
    public func albumContextTracksByTrackID(
        for tracks: [Track],
        requiresMutationMetadata: Bool = true
    ) async -> [String: [Track]] {
        let contextTracks = await availableTracksWithMutationMetadata(
            tracks,
            requiresMutationMetadata: requiresMutationMetadata
        )
        return Self.albumTracksByTrackID(for: contextTracks)
    }

    /// Returns artist-level genre evidence after restoring AppleScript-only metadata.
    ///
    /// Grouping happens after enrichment so an authoritative `albumArtist` can
    /// prevent a feature-credit track from borrowing evidence from another artist.
    /// Unmapped tracks remain unchanged, and unavailable tracks remain in the
    /// context, because they are read-only genre evidence rather than write targets.
    public func artistContextTracksByTrackID(for tracks: [Track]) async -> [String: [Track]] {
        let contextTracks = await enrichTracks(
            tracks,
            requiresMutationMetadata: false
        )
        return Self.artistTracksByTrackID(for: contextTracks)
    }

    private static func genreContextTracks(
        track: Track,
        artistTracks: [Track],
        albumTracks: [Track]
    ) -> [Track] {
        if !artistTracks.isEmpty {
            return tracks(artistTracks, containing: track)
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
        await markPendingAlbum(
            track: track,
            reason: .prerelease,
            metadata: metadata,
            recheckDays: runtimeConfiguration.prereleaseRecheckDays
        )
    }

    func markPendingAlbum(
        track: Track,
        reason: PendingAlbumReason,
        metadata: [String: String],
        recheckDays: Int?
    ) async {
        let identity = track.albumIdentity
        await pendingVerificationService?.markForVerification(
            artist: identity.artist,
            album: identity.album,
            reason: reason.rawValue,
            metadata: metadata,
            recheckDays: recheckDays
        )
    }

    func trackWithMutationMetadata(
        _ track: Track,
        requiresMutationMetadata: Bool = true
    ) async throws -> Track {
        guard let idMapper else {
            return track
        }

        guard let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) else {
            guard requiresMutationMetadata else {
                return track
            }
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        }

        return enrichedTrack
    }

    func availableTracksWithMutationMetadata(
        _ tracks: [Track],
        requiresMutationMetadata: Bool = true
    ) async -> [Track] {
        await enrichTracks(
            tracks,
            requiresMutationMetadata: requiresMutationMetadata
        ).filter(Self.isTrackAvailableForProcessing)
    }

    private func enrichTracks(
        _ tracks: [Track],
        requiresMutationMetadata: Bool
    ) async -> [Track] {
        guard let idMapper else {
            return tracks
        }

        var enrichedTracks: [Track] = []
        enrichedTracks.reserveCapacity(tracks.count)
        for track in tracks {
            if let enrichedTrack = await idMapper.trackWithAppleScriptMetadata(for: track) {
                enrichedTracks.append(enrichedTrack)
            } else if !requiresMutationMetadata {
                enrichedTracks.append(track)
            }
        }
        return enrichedTracks
    }

    // MARK: Multi-Track

    /// Updates tracks individually, aggregates non-fatal failures, and records change history.
    ///
    /// Pass a run-owned `yearRunScope` when invoking this method in per-track chunks.
    /// Returns a `BatchUpdateResult` with both successes and failures.
    public func updateTracks(
        _ tracks: [Track],
        options: UpdateOptions,
        pass: UpdatePass = .standard,
        albumTracksProvider: (@Sendable (Track) -> [Track])? = nil,
        artistTracksProvider: (@Sendable (Track) -> [Track])? = nil,
        yearRunScope: YearRunScope? = nil,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async throws -> BatchUpdateResult {
        let signpostState = AppSignpost.batchProcessing.beginInterval("updateTracks")
        defer { AppSignpost.batchProcessing.endInterval("updateTracks", signpostState) }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []
        let trackProviders = await makeUpdateTrackProviders(
            tracks: tracks,
            albumTracksProvider: albumTracksProvider,
            artistTracksProvider: artistTracksProvider
        )
        let yearRunScope = yearRunScope ?? YearRunScope()

        for (index, track) in tracks.enumerated() {
            do {
                let trackOutcome = try await applyGeneratedAcceptedChanges(
                    for: GeneratedUpdateRequest(track: track, options: options, pass: pass),
                    trackProviders: trackProviders,
                    yearRunScope: yearRunScope,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
                entries.append(contentsOf: trackOutcome.entries)
                noOpEntries.append(contentsOf: trackOutcome.noOpEntries)
            } catch {
                try recordWorkflowWriteFailure(
                    error,
                    isReviewedChange: false,
                    trackID: track.id,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions
                )
            }

            Self.reportUpdateProgress(index: index, total: tracks.count, progressHandler: progressHandler)
        }

        Self.reportUpdateComplete(total: tracks.count, progressHandler: progressHandler)

        if !errorDescriptions.isEmpty, entries.isEmpty, noOpEntries.isEmpty {
            throw UpdateCoordinatorError.allTracksFailed(
                count: Set(failedTrackIDs).count,
                errorDescriptions: errorDescriptions
            )
        }

        return BatchUpdateResult(
            entries: entries,
            noOpEntries: noOpEntries,
            failedTrackIDs: failedTrackIDs,
            errorDescriptions: errorDescriptions
        )
    }

    private func makeUpdateTrackProviders(
        tracks: [Track],
        albumTracksProvider: (@Sendable (Track) -> [Track])?,
        artistTracksProvider: (@Sendable (Track) -> [Track])?
    ) async -> UpdateTrackProviders {
        let contextTracks = if albumTracksProvider == nil || artistTracksProvider == nil {
            await enrichTracks(tracks, requiresMutationMetadata: false)
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
        let tracksByArtist = Dictionary(grouping: tracks) {
            normalizeForMatching(AlbumIdentity.groupingArtist(for: $0))
        }
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            let artistKey = normalizeForMatching(AlbumIdentity.groupingArtist(for: track))
            return (track.id, tracksByArtist[artistKey] ?? [])
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
        progressHandler: @Sendable (ProgressUpdate) -> Void,
        checkpoint: WorkCheckpointSink? = nil
    ) async throws -> BatchUpdateResult {
        guard let analytics else {
            return try await applyAcceptedChangesBody(
                changes,
                progressHandler: progressHandler,
                checkpoint: checkpoint
            )
        }
        return try await analytics.measure(.batchWrite) {
            try await self.applyAcceptedChangesBody(
                changes,
                progressHandler: progressHandler,
                checkpoint: checkpoint
            )
        }
    }

    private func applyAcceptedChangesBody(
        _ changes: [ProposedChange],
        progressHandler: @Sendable (ProgressUpdate) -> Void,
        checkpoint: WorkCheckpointSink?
    ) async throws -> BatchUpdateResult {
        let accepted = changes.filter(\.isAccepted)
        guard !accepted.isEmpty else {
            throw UpdateCoordinatorError.noChangesProduced
        }
        var acceptedIDs: Set<UUID> = []
        if let duplicate = accepted.first(where: { !acceptedIDs.insert($0.id).inserted }) {
            throw UpdateCoordinatorError.duplicateChangeID(duplicate.id)
        }

        var entries: [ChangeLogEntry] = []
        var noOpEntries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        var index = 0
        while index < accepted.count {
            let changeGroup = reviewedChangeGroup(in: accepted, startingAt: index)
            let groupOutcome: AppliedChangeEntries
            do {
                groupOutcome = try await applyReviewedChangeGroup(
                    changeGroup,
                    failedTrackIDs: &failedTrackIDs,
                    errorDescriptions: &errorDescriptions,
                    checkpoint: checkpoint
                )
            } catch {
                guard !entries.isEmpty else { throw error }
                throw PartialWriteError(
                    appliedTrackIDs: Set(entries.map(\.trackID)),
                    underlyingError: error
                )
            }
            entries.append(contentsOf: groupOutcome.entries)
            noOpEntries.append(contentsOf: groupOutcome.noOpEntries)

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

        if !errorDescriptions.isEmpty, entries.isEmpty, noOpEntries.isEmpty {
            throw UpdateCoordinatorError.allTracksFailed(
                count: Set(failedTrackIDs).count,
                errorDescriptions: errorDescriptions
            )
        }

        return BatchUpdateResult(
            entries: entries,
            noOpEntries: noOpEntries,
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
        case let .reviewedChangeStale(trackID, _):
            Self.recordFailedTrack(
                id: trackID,
                error: error,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
            log.info("Skipped stale reviewed change for track \(trackID, privacy: .private)")
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

    func recordUnexpectedFailure(
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
            "Failed workflow operation for track \(trackID, privacy: .private): \(error.localizedDescription, privacy: .private)"
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
