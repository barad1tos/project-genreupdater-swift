import Core
import Services

struct UpdateRunReport: Equatable {
    let scopeTitle: String
    let changedEntries: [ChangeLogEntry]
    let albumGroups: [UpdateRunAlbumGroup]
    let albumResults: [UpdateRunAlbumResult]
    let changeBreakdown: [UpdateRunChangeBreakdown]
    let outcomeBreakdown: [UpdateRunOutcomeBreakdown]
    let failures: [UpdateRunFailure]
    let noOpCount: Int
    let skippedCount: Int
    let scannedTrackCount: Int
    let displayMode: ChangeDisplayMode
    let pendingVerification: UpdateRunPendingVerificationSummary?
    let databaseVerification: UpdateRunDatabaseVerificationSummary?
    let recovery: UpdateRunRecoverySummary?
    init(
        result: BatchUpdateResult?,
        completedEntries: [ChangeLogEntry],
        trackStatuses: [String: TrackProcessingStatus],
        tracks: [Track],
        testArtists: [String],
        displayMode: ChangeDisplayMode = .compact,
        operationalContext: UpdateRunOperationalContext = .empty
    ) {
        let allEntries = result?.entries ?? completedEntries
        let entries = allEntries.filter(Self.isRealChange)
        let noOpEntries = if let result {
            result.noOpEntries + result.entries.filter { !Self.isRealChange($0) }
        } else {
            completedEntries.filter { !Self.isRealChange($0) }
        }
        let trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let failureItems = Self.makeFailures(
            result: result,
            trackStatuses: trackStatuses,
            trackLookup: trackLookup,
            entries: entries + noOpEntries
        )
        changedEntries = entries
        noOpCount = noOpEntries.count
        albumGroups = Self.makeAlbumGroups(from: entries, trackLookup: trackLookup)
        changeBreakdown = Self.makeChangeBreakdown(from: entries, trackLookup: trackLookup)
        failures = failureItems
        outcomeBreakdown = Self.makeOutcomeBreakdown(
            noOpEntries: noOpEntries,
            failures: failureItems,
            trackStatuses: trackStatuses,
            trackLookup: trackLookup
        )
        albumResults = Self.makeAlbumResults(
            entries: entries,
            noOpEntries: noOpEntries,
            failures: failureItems,
            tracks: tracks,
            trackStatuses: trackStatuses
        )
        skippedCount = trackStatuses.values.count { status in
            if case .skipped = status {
                return true
            }
            return false
        }
        scannedTrackCount = trackStatuses.isEmpty ? tracks.count : trackStatuses.count
        self.displayMode = displayMode
        pendingVerification = operationalContext.pendingVerification
        databaseVerification = operationalContext.databaseVerification
        recovery = operationalContext.recovery
        scopeTitle = Self.makeScopeTitle(testArtists: testArtists)
    }

    var changedTrackCount: Int {
        Set(changedEntries.map(\.trackID)).count
    }
    var affectedAlbumCount: Int {
        albumResults.count
    }
    var affectedArtistCount: Int {
        Set(albumResults.map { normalizeForMatching($0.artist) }).count
    }
    var hasFailures: Bool {
        !failures.isEmpty
    }
    var hasOperationalNotes: Bool {
        !operationalNotes.isEmpty
    }
    var operationalNotes: [UpdateRunOperationalNote] {
        var notes: [UpdateRunOperationalNote] = []
        if !failures.isEmpty {
            notes.append(UpdateRunOperationalNote(
                id: "failures",
                title: "Needs Attention",
                detail: "\(failures.count.formatted()) \(Self.issueNoun(failures.count)) found.",
                severity: .failure
            ))
        }
        if skippedCount > 0 {
            notes.append(UpdateRunOperationalNote(
                id: "skipped",
                title: "Skipped",
                detail: "Skipped tracks: \(skippedCount.formatted()).",
                severity: .warning
            ))
        }
        if let pendingVerification, pendingVerification.total > 0 {
            var detail = "\(pendingVerification.total.formatted()) pending, "
                + "\(pendingVerification.due.formatted()) due, "
                + "\(pendingVerification.problematic.formatted()) problematic"
            if pendingVerification.skippedByInterval > 0 {
                detail += ", \(pendingVerification.skippedByInterval.formatted()) skipped"
            }
            if pendingVerification.verified > 0 {
                detail += ", \(pendingVerification.verified.formatted()) verified"
            }
            notes.append(UpdateRunOperationalNote(
                id: "pending-verification",
                title: "Pending Verification",
                detail: detail + ".",
                severity: pendingVerification.problematic > 0 ? .warning : .info
            ))
        }
        if let databaseVerification {
            notes.append(UpdateRunOperationalNote(
                id: "database-verification",
                title: "Database Verification",
                detail: Self.databaseVerificationNote(databaseVerification),
                severity: Self.databaseVerificationSeverity(databaseVerification)
            ))
        }
        if let recovery {
            notes.append(UpdateRunOperationalNote(
                id: "recovery",
                title: "Recovery",
                detail: "\(recovery.restoredCount.formatted()) restored, "
                    + "\(recovery.skippedCount.formatted()) skipped, "
                    + "\(recovery.failedCount.formatted()) failed.",
                severity: recovery.failedCount > 0 ? .warning : .info
            ))
        }
        if changedEntries.isEmpty, failures.isEmpty {
            notes.append(UpdateRunOperationalNote(
                id: "no-changes",
                title: "No Changes",
                detail: "No metadata changes were made during this run.",
                severity: .info
            ))
        }
        return notes
    }
    var title: String {
        hasFailures ? "Finished with \(failures.count.formatted()) \(Self.issueNoun(failures.count))" : "Update Complete"
    }

    private static func makeScopeTitle(testArtists: [String]) -> String {
        let normalizedArtists = ArtistAllowList.normalized(testArtists)
        guard !normalizedArtists.isEmpty else { return "Full effective scope" }
        if normalizedArtists.count == 1, let artist = normalizedArtists.first {
            return "Test Artist: \(artist)"
        }
        return "Test Artists: \(normalizedArtists.count)"
    }
    private static func makeAlbumGroups(
        from entries: [ChangeLogEntry],
        trackLookup: [String: Track]
    ) -> [UpdateRunAlbumGroup] {
        var buckets: [UpdateRunAlbumGroupKey: (firstIndex: Int, entries: [ChangeLogEntry])] = [:]

        for (index, entry) in entries.enumerated() {
            let values = valuePair(for: entry)
            let identity = albumIdentity(for: entry, trackLookup: trackLookup)
            let key = UpdateRunAlbumGroupKey(
                identity: identity,
                changeType: entry.changeType,
                oldValue: values.old,
                newValue: values.new
            )
            var bucket = buckets[key] ?? (firstIndex: index, entries: [])
            bucket.firstIndex = min(bucket.firstIndex, index)
            bucket.entries.append(entry)
            buckets[key] = bucket
        }

        return buckets
            .map { key, bucket in
                UpdateRunAlbumGroup(
                    artist: key.artist,
                    album: key.album,
                    changeType: key.changeType,
                    oldValue: key.oldValue,
                    newValue: key.newValue,
                    entries: bucket.entries.sorted {
                        $0.trackName.localizedStandardCompare($1.trackName) == .orderedAscending
                    },
                    sortIndex: bucket.firstIndex
                )
            }
            .sorted(by: albumGroupSort)
    }
    private static func albumGroupSort(_ left: UpdateRunAlbumGroup, _ right: UpdateRunAlbumGroup) -> Bool {
        let artistOrder = left.artist.localizedStandardCompare(right.artist)
        if artistOrder != .orderedSame {
            return artistOrder == .orderedAscending
        }

        let albumOrder = left.album.localizedStandardCompare(right.album)
        if albumOrder != .orderedSame {
            return albumOrder == .orderedAscending
        }

        if left.sortIndex != right.sortIndex {
            return left.sortIndex < right.sortIndex
        }

        let typeOrder = left.changeType.displayLabel.localizedStandardCompare(right.changeType.displayLabel)
        if typeOrder != .orderedSame {
            return typeOrder == .orderedAscending
        }

        let valueOrder = left.changeSummary.localizedStandardCompare(right.changeSummary)
        return valueOrder == .orderedAscending
    }
    private static func makeFailures(
        result: BatchUpdateResult?,
        trackStatuses: [String: TrackProcessingStatus],
        trackLookup: [String: Track],
        entries: [ChangeLogEntry]
    ) -> [UpdateRunFailure] {
        var failureMessages = failureMessages(from: result, trackStatuses: trackStatuses)
        let resultFailedTrackIDs = Set(result?.failedTrackIDs ?? [])
        let entriesByTrackID = Dictionary(grouping: entries, by: \.trackID)

        for (trackID, status) in trackStatuses {
            if case let .failed(message) = status, !resultFailedTrackIDs.contains(trackID) {
                failureMessages.append((trackID: trackID, message: message))
            }
        }

        return failureMessages
            .enumerated()
            .map { index, failure in
                let trackID = failure.trackID
                let track = trackLookup[trackID]
                let entry = entriesByTrackID[trackID]?.first
                let identity = track.map { albumIdentity(for: $0) }
                    ?? entry.map { albumIdentity(for: $0, trackLookup: trackLookup) }
                return UpdateRunFailure(
                    id: "\(trackID)\u{1F}\(index)",
                    title: track?.name ?? entry.map(fallbackTrackTitle) ?? "Unknown track",
                    subtitle: track.map { "\($0.artist) - \($0.album)" }
                        ?? entry.map { "\($0.artist) - \($0.albumName)" }
                        ?? "Track ID: \(trackID)",
                    message: failure.message,
                    technicalID: trackID,
                    hasKnownTrack: track != nil,
                    artist: identity?.artist ?? "Unknown artist",
                    album: identity?.album ?? "Unknown album"
                )
            }
            .sorted { left, right in
                left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }
    private static func makeChangeBreakdown(
        from entries: [ChangeLogEntry],
        trackLookup: [String: Track]
    ) -> [UpdateRunChangeBreakdown] {
        Dictionary(grouping: entries, by: \.changeType)
            .map { changeType, entries in
                UpdateRunChangeBreakdown(
                    changeType: changeType,
                    changeCount: entries.count,
                    trackCount: Set(entries.map(\.trackID)).count,
                    albumCount: Set(entries.map { albumIdentity(for: $0, trackLookup: trackLookup) }).count
                )
            }
            .sorted { left, right in
                left.changeType.displayLabel
                    .localizedStandardCompare(right.changeType.displayLabel) == .orderedAscending
            }
    }
    private static func makeAlbumResults(
        entries: [ChangeLogEntry],
        noOpEntries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        tracks: [Track],
        trackStatuses: [String: TrackProcessingStatus]
    ) -> [UpdateRunAlbumResult] {
        let trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let changesByTrackID = Dictionary(grouping: entries, by: \.trackID)
        let noOpChangesByTrackID = Dictionary(grouping: noOpEntries, by: \.trackID)
        let noOpTrackIDs = Set(noOpEntries.map(\.trackID))
        let failuresByTrackID = Dictionary(grouping: failures, by: \.technicalID)
        let resultEntries = entries + noOpEntries
        let albumKeys = albumResultKeys(
            entries: resultEntries,
            failures: failures,
            trackLookup: trackLookup
        )

        return albumKeys.map { key in
            let albumTracks = tracks
                .filter { track in
                    albumIdentity(for: track) == key
                }
                .sorted(by: trackSort)
            let fallbackRows = fallbackRowsForMissingTracks(
                key: key,
                entries: resultEntries,
                failures: failures,
                trackLookup: trackLookup,
                noOpTrackIDs: noOpTrackIDs
            )
            let trackRows = albumTracks.map { track in
                makeTrackResult(
                    track: track,
                    entries: (
                        applied: changesByTrackID[track.id] ?? [],
                        noOp: noOpChangesByTrackID[track.id] ?? []
                    ),
                    failures: failuresByTrackID[track.id] ?? [],
                    status: trackStatuses[track.id],
                    noOpTrackIDs: noOpTrackIDs
                )
            } + fallbackRows

            return UpdateRunAlbumResult(
                artist: key.artist,
                album: key.album,
                tracks: trackRows,
                sortTitle: "\(key.artist) \(key.album)"
            )
        }
        .sorted(by: albumResultSort)
    }
    private static func albumResultKeys(
        entries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        trackLookup: [String: Track]
    ) -> Set<UpdateRunAlbumIdentity> {
        var keys = Set<UpdateRunAlbumIdentity>()
        for entry in entries {
            keys.insert(albumIdentity(for: entry, trackLookup: trackLookup))
        }
        for failure in failures {
            keys.insert(UpdateRunAlbumIdentity(artist: failure.artist, album: failure.album))
        }
        return keys
    }

    private static func fallbackRowsForMissingTracks(
        key: UpdateRunAlbumIdentity,
        entries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        trackLookup: [String: Track],
        noOpTrackIDs: Set<String>
    ) -> [UpdateRunTrackResult] {
        let entriesByTrackID = Dictionary(grouping: entries.filter { entry in
            trackLookup[entry.trackID] == nil
                && albumIdentity(for: entry, trackLookup: trackLookup) == key
        }, by: \.trackID)
        let failuresByTrackID = Dictionary(grouping: failures.filter { failure in
            trackLookup[failure.technicalID] == nil
                && UpdateRunAlbumIdentity(artist: failure.artist, album: failure.album) == key
        }, by: \.technicalID)
        let trackIDs = Set(entriesByTrackID.keys).union(failuresByTrackID.keys)

        return trackIDs.map { trackID in
            let trackEntries = entriesByTrackID[trackID] ?? []
            let trackFailures = failuresByTrackID[trackID] ?? []
            let appliedEntries = trackEntries.filter(isRealChange)
            let noOpEntries = trackEntries.filter { !isRealChange($0) }
            let failureMessage = trackFailures.isEmpty ? nil : trackFailures.map(\.message).joined(separator: "\n")
            let entry = trackEntries.first
            let failure = trackFailures.first
            return UpdateRunTrackResult(
                id: entry == nil ? failure?.id ?? trackID : trackID,
                technicalID: trackID,
                title: entry.map(fallbackTrackTitle) ?? failure?.title ?? "Unknown track",
                trackNumber: nil,
                currentGenre: entry?.oldGenre,
                currentYear: entry.flatMap { MusicAppYear.normalized($0.oldYear) },
                releaseYear: nil,
                trackStatus: nil,
                changes: appliedEntries.map(makeChangeSummary),
                noOpChanges: noOpEntries.map(makeChangeSummary),
                failureMessage: failureMessage,
                processingStatus: failureMessage.map(TrackProcessingStatus.failed),
                outcome: makeTrackOutcome(
                    trackID: trackID,
                    failureMessage: failureMessage,
                    changes: appliedEntries,
                    noOpTrackIDs: noOpTrackIDs,
                    status: nil
                )
            )
        }.sorted { left, right in
            let titleOrder = left.title.localizedStandardCompare(right.title)
            return titleOrder == .orderedSame ? left.id < right.id : titleOrder == .orderedAscending
        }
    }

    private static func makeTrackResult(
        track: Track,
        entries: (applied: [ChangeLogEntry], noOp: [ChangeLogEntry]),
        failures: [UpdateRunFailure],
        status: TrackProcessingStatus?,
        noOpTrackIDs: Set<String>
    ) -> UpdateRunTrackResult {
        let failureMessage = failures.isEmpty ? nil : failures.map(\.message).joined(separator: "\n")
        return UpdateRunTrackResult(
            id: track.id,
            technicalID: track.id,
            title: track.name,
            trackNumber: track.originalPosition,
            currentGenre: track.genre,
            currentYear: track.year,
            releaseYear: track.releaseYear,
            trackStatus: track.trackStatus,
            changes: entries.applied.map(makeChangeSummary),
            noOpChanges: entries.noOp.map(makeChangeSummary),
            failureMessage: failureMessage,
            processingStatus: status,
            outcome: makeTrackOutcome(
                trackID: track.id,
                failureMessage: failureMessage,
                changes: entries.applied,
                noOpTrackIDs: noOpTrackIDs,
                status: status
            )
        )
    }

    private static func makeTrackOutcome(
        trackID: String,
        failureMessage: String?,
        changes: [ChangeLogEntry],
        noOpTrackIDs: Set<String>,
        status: TrackProcessingStatus?
    ) -> UpdateRunTrackOutcome {
        if let failureMessage {
            return .failed(message: failureMessage)
        }
        if !changes.isEmpty {
            return .applied
        }
        if noOpTrackIDs.contains(trackID) {
            return .noChange
        }
        if case .skipped = status {
            return .skipped
        }
        return .unchanged
    }

    private static func makeChangeSummary(_ entry: ChangeLogEntry) -> UpdateRunChangeSummary {
        let values = valuePair(for: entry)
        return UpdateRunChangeSummary(
            id: entry.id.uuidString,
            changeType: entry.changeType,
            oldValue: values.old,
            newValue: values.new
        )
    }

    private static func fallbackTrackTitle(_ entry: ChangeLogEntry) -> String {
        entry.trackName.isEmpty ? "Unknown track" : entry.trackName
    }

    static func albumIdentity(for track: Track) -> UpdateRunAlbumIdentity {
        let identity = AlbumIdentity(track: track)
        return UpdateRunAlbumIdentity(identity: identity)
    }

    static func albumIdentity(
        for entry: ChangeLogEntry,
        trackLookup: [String: Track]
    ) -> UpdateRunAlbumIdentity {
        if let track = trackLookup[entry.trackID] {
            return albumIdentity(for: track)
        }
        return UpdateRunAlbumIdentity(artist: entry.artist, album: entry.albumName)
    }

    private static func trackSort(_ left: Track, _ right: Track) -> Bool {
        if let leftPosition = left.originalPosition,
           let rightPosition = right.originalPosition,
           leftPosition != rightPosition {
            return leftPosition < rightPosition
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    private static func albumResultSort(_ left: UpdateRunAlbumResult, _ right: UpdateRunAlbumResult) -> Bool {
        if left.failureCount != right.failureCount {
            return left.failureCount > right.failureCount
        }
        if left.changedTrackCount != right.changedTrackCount {
            return left.changedTrackCount > right.changedTrackCount
        }
        return left.sortTitle.localizedStandardCompare(right.sortTitle) == .orderedAscending
    }

    private static func failureMessages(
        from result: BatchUpdateResult?,
        trackStatuses: [String: TrackProcessingStatus]
    ) -> [(trackID: String, message: String)] {
        guard let result else { return [] }
        return result.failedTrackIDs.enumerated().map { index, trackID in
            let message = result.errorDescriptions[safe: index]
                ?? statusFailureMessage(trackStatuses[trackID])
                ?? "No failure details were captured for this run."
            return (
                trackID: trackID,
                message: message
            )
        }
    }

    private static func statusFailureMessage(_ status: TrackProcessingStatus?) -> String? {
        guard case let .failed(message) = status else { return nil }
        return message
    }

    private static func valuePair(for entry: ChangeLogEntry) -> (old: String, new: String) {
        switch entry.changeType {
        case .genreUpdate:
            (entry.oldGenre ?? "none", entry.newGenre ?? "none")
        case .yearUpdate, .yearRevert:
            (
                MusicAppYear.normalized(entry.oldYear).map(String.init) ?? "none",
                MusicAppYear.normalized(entry.newYear).map(String.init) ?? "none"
            )
        case .trackCleaning:
            (entry.oldTrackName ?? "none", entry.newTrackName ?? "none")
        case .albumCleaning:
            (entry.oldAlbumName ?? "none", entry.newAlbumName ?? "none")
        case .artistRename:
            artistValuePair(for: entry)
        }
    }

    private static func artistValuePair(for entry: ChangeLogEntry) -> (old: String, new: String) {
        let values = ChangeDisplay.values(
            oldValue: entry.oldArtist ?? "none",
            newValue: entry.newArtist ?? "none",
            albumArtistChange: entry.albumArtistChange
        )
        return (values.oldValue ?? "none", values.newValue ?? "none")
    }

    private static func isRealChange(_ entry: ChangeLogEntry) -> Bool {
        switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre != entry.newGenre
        case .yearUpdate, .yearRevert:
            MusicAppYear.normalized(entry.oldYear) != MusicAppYear.normalized(entry.newYear)
        case .trackCleaning:
            entry.oldTrackName != entry.newTrackName
        case .albumCleaning:
            entry.oldAlbumName != entry.newAlbumName
        case .artistRename:
            entry.oldArtist != entry.newArtist
        }
    }

    private static func issueNoun(_ count: Int) -> String {
        count == 1 ? "issue" : "issues"
    }

    private static func databaseVerificationNote(
        _ databaseVerification: UpdateRunDatabaseVerificationSummary
    ) -> String {
        if let error = databaseVerification.error {
            return "Skipped: \(error)"
        }
        if databaseVerification.skippedDueToRecentVerification {
            return "\(databaseVerification.verifiedTrackCount.formatted()) tracks in store; skipped after recent check."
        }
        return "\(databaseVerification.verifiedTrackCount.formatted()) verified, "
            + "\(databaseVerification.removedCount.formatted()) removed."
    }

    private static func databaseVerificationSeverity(
        _ databaseVerification: UpdateRunDatabaseVerificationSummary
    ) -> UpdateRunOperationalNote.Severity {
        if databaseVerification.error != nil || databaseVerification.removedCount > 0 {
            return .warning
        }
        return .info
    }
}

struct UpdateRunAlbumGroup: Identifiable, Equatable {
    let artist: String
    let album: String
    let changeType: ChangeType
    let oldValue: String
    let newValue: String
    let entries: [ChangeLogEntry]
    let sortIndex: Int

    var id: String {
        [artist, album, changeType.rawValue, oldValue, newValue].joined(separator: "\u{1F}")
    }
    var title: String {
        "\(artist) - \(album)"
    }
    var changedTrackCount: Int {
        Set(entries.map(\.trackID)).count
    }
    var changeSummary: String {
        "\(oldValue) -> \(newValue)"
    }
}

struct UpdateRunFailure: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let message: String
    let technicalID: String
    let hasKnownTrack: Bool
    let artist: String
    let album: String
}

struct UpdateRunAlbumResult: Identifiable, Equatable {
    let artist: String
    let album: String
    let tracks: [UpdateRunTrackResult]
    let sortTitle: String

    var id: String {
        [artist, album].joined(separator: "\u{1F}")
    }
    var title: String {
        "\(artist) - \(album)"
    }
    var changedTrackCount: Int {
        tracks.count { $0.hasChanges }
    }
    var failureCount: Int {
        tracks.reduce(0) { count, track in
            count + (track.failureMessage.map { failureMessage in
                max(1, failureMessage.components(separatedBy: "\n").count)
            } ?? 0)
        }
    }
    var trackCount: Int {
        tracks.count
    }
    var needsReview: Bool {
        failureCount > 0
    }

    var primaryGenre: String? {
        mostFrequentValue(tracks.compactMap(\.currentGenre).filter { !$0.isEmpty })
    }

    var currentYear: Int? {
        mostFrequentValue(tracks.compactMap(\.currentYear))
    }
    var releaseYear: Int? {
        mostFrequentValue(tracks.compactMap(\.releaseYear))
    }

    var primaryChangeSummary: String {
        let summaries = Set(tracks.flatMap(\.changes).map(\.summary))
        if summaries.count == 1, let summary = summaries.first {
            return summary
        }
        if summaries.isEmpty {
            return "No metadata changes"
        }
        return "\(summaries.count) metadata changes"
    }

    private func mostFrequentValue<Value: Hashable>(_ values: [Value]) -> Value? {
        Dictionary(grouping: values, by: { $0 })
            .mapValues(\.count)
            .max { left, right in left.value < right.value }?
            .key
    }
}

struct UpdateRunAlbumIdentity: Hashable {
    let key: String
    let artist: String
    let album: String

    init(artist: String, album: String) {
        self.init(identity: AlbumIdentity(artist: artist, album: album))
    }

    init(identity: AlbumIdentity) {
        key = identity.key
        artist = identity.artist
        album = identity.album
    }

    static func == (leftIdentity: Self, rightIdentity: Self) -> Bool {
        leftIdentity.key == rightIdentity.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

private struct UpdateRunAlbumGroupKey: Hashable {
    let identityKey: String
    let artist: String
    let album: String
    let changeType: ChangeType
    let oldValue: String
    let newValue: String

    init(
        identity: UpdateRunAlbumIdentity,
        changeType: ChangeType,
        oldValue: String,
        newValue: String
    ) {
        identityKey = identity.key
        artist = identity.artist
        album = identity.album
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
    }

    static func == (leftKey: Self, rightKey: Self) -> Bool {
        leftKey.identityKey == rightKey.identityKey
            && leftKey.changeType == rightKey.changeType
            && leftKey.oldValue == rightKey.oldValue
            && leftKey.newValue == rightKey.newValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identityKey)
        hasher.combine(changeType)
        hasher.combine(oldValue)
        hasher.combine(newValue)
    }
}
