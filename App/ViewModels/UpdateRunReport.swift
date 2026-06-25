import Core
import Services

struct UpdateRunOperationalNote: Identifiable, Equatable {
    enum Severity: Equatable { case info, warning, failure }

    let id: String
    let title: String
    let detail: String
    let severity: Severity
}
struct UpdateRunPendingVerificationSummary: Equatable {
    let total: Int
    let due: Int
    let problematic: Int
}
struct UpdateRunReport: Equatable {
    let scopeTitle: String
    let changedEntries: [ChangeLogEntry]
    let albumGroups: [UpdateRunAlbumGroup]
    let albumResults: [UpdateRunAlbumResult]
    let changeBreakdown: [UpdateRunChangeBreakdown]
    let outcomeBreakdown: [UpdateRunOutcomeBreakdown]
    let failures: [UpdateRunFailure]
    let skippedCount: Int
    let scannedTrackCount: Int
    let displayMode: ChangeDisplayMode
    let pendingVerification: UpdateRunPendingVerificationSummary?
    init(
        result: BatchUpdateResult?,
        completedEntries: [ChangeLogEntry],
        trackStatuses: [String: TrackProcessingStatus],
        tracks: [Track],
        testArtists: [String],
        displayMode: ChangeDisplayMode = .compact,
        pendingVerification: UpdateRunPendingVerificationSummary? = nil
    ) {
        let allEntries = result?.entries ?? completedEntries
        let entries = allEntries.filter(Self.isRealChange)
        let noOpEntries = if let result {
            result.noOpEntries + result.entries.filter { !Self.isRealChange($0) }
        } else {
            completedEntries.filter { !Self.isRealChange($0) }
        }
        let resultEntries = entries + noOpEntries
        let trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let failureItems = Self.makeFailures(
            result: result,
            trackStatuses: trackStatuses,
            trackLookup: trackLookup
        )
        changedEntries = entries
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
            resultEntries: resultEntries,
            failures: failureItems,
            tracks: tracks,
            trackStatuses: trackStatuses
        )
        skippedCount = trackStatuses.values.count { status in
            if case .skipped = status { return true }
            return false
        }
        scannedTrackCount = trackStatuses.isEmpty ? tracks.count : trackStatuses.count
        self.displayMode = displayMode
        self.pendingVerification = pendingVerification
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
            notes.append(UpdateRunOperationalNote(
                id: "pending-verification",
                title: "Pending Verification",
                detail: "\(pendingVerification.total.formatted()) pending, "
                    + "\(pendingVerification.due.formatted()) due, "
                    + "\(pendingVerification.problematic.formatted()) problematic.",
                severity: pendingVerification.problematic > 0 ? .warning : .info
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
        trackLookup: [String: Track]
    ) -> [UpdateRunFailure] {
        var failureMessages = failureMessages(from: result, trackStatuses: trackStatuses)
        let resultFailedTrackIDs = Set(result?.failedTrackIDs ?? [])

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
                let identity = track.map { albumIdentity(for: $0) }
                return UpdateRunFailure(
                    id: "\(trackID)\u{1F}\(index)",
                    title: track?.name ?? "Unknown track",
                    subtitle: track.map { "\($0.artist) - \($0.album)" } ?? "Track ID: \(trackID)",
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
        resultEntries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        tracks: [Track],
        trackStatuses: [String: TrackProcessingStatus]
    ) -> [UpdateRunAlbumResult] {
        let trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let changesByTrackID = Dictionary(grouping: entries, by: \.trackID)
        let failuresByTrackID = Dictionary(grouping: failures, by: \.technicalID)
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
                trackLookup: trackLookup
            )
            let trackRows = albumTracks.map { track in
                makeTrackResult(
                    track: track,
                    changes: changesByTrackID[track.id] ?? [],
                    failures: failuresByTrackID[track.id] ?? [],
                    status: trackStatuses[track.id]
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
        trackLookup: [String: Track]
    ) -> [UpdateRunTrackResult] {
        let missingEntryRows = entries
            .filter { entry in
                trackLookup[entry.trackID] == nil
                    && albumIdentity(for: entry, trackLookup: trackLookup) == key
            }
            .map { entry in
                makeFallbackTrackResult(entry: entry)
            }
        let missingFailureRows = failures
            .filter { failure in
                trackLookup[failure.technicalID] == nil
                    && UpdateRunAlbumIdentity(artist: failure.artist, album: failure.album) == key
            }
            .map { failure in
                makeFallbackTrackResult(failure: failure)
            }
        return (missingEntryRows + missingFailureRows).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func makeTrackResult(
        track: Track,
        changes: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        status: TrackProcessingStatus?
    ) -> UpdateRunTrackResult {
        UpdateRunTrackResult(
            id: track.id,
            technicalID: track.id,
            title: track.name,
            trackNumber: track.originalPosition,
            currentGenre: track.genre,
            currentYear: track.year,
            releaseYear: track.releaseYear,
            trackStatus: track.trackStatus,
            changes: changes.map(makeChangeSummary),
            failureMessage: failures.isEmpty ? nil : failures.map(\.message).joined(separator: "\n"),
            processingStatus: status
        )
    }

    private static func makeFallbackTrackResult(entry: ChangeLogEntry) -> UpdateRunTrackResult {
        UpdateRunTrackResult(
            id: entry.trackID,
            technicalID: entry.trackID,
            title: entry.trackName.isEmpty ? "Unknown track" : entry.trackName,
            trackNumber: nil,
            currentGenre: entry.oldGenre,
            currentYear: entry.oldYear,
            releaseYear: nil,
            trackStatus: nil,
            changes: [makeChangeSummary(entry)],
            failureMessage: nil,
            processingStatus: nil
        )
    }

    private static func makeFallbackTrackResult(failure: UpdateRunFailure) -> UpdateRunTrackResult {
        UpdateRunTrackResult(
            id: failure.id,
            technicalID: failure.technicalID,
            title: failure.title,
            trackNumber: nil,
            currentGenre: nil,
            currentYear: nil,
            releaseYear: nil,
            trackStatus: nil,
            changes: [],
            failureMessage: failure.message,
            processingStatus: .failed(failure.message)
        )
    }

    private static func makeChangeSummary(_ entry: ChangeLogEntry) -> UpdateRunChangeSummary {
        let values = valuePair(for: entry)
        return UpdateRunChangeSummary(
            changeType: entry.changeType,
            oldValue: values.old,
            newValue: values.new
        )
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
            (entry.oldYear.map(String.init) ?? "none", entry.newYear.map(String.init) ?? "none")
        case .trackCleaning:
            (entry.oldTrackName ?? "none", entry.newTrackName ?? "none")
        case .albumCleaning:
            (entry.oldAlbumName ?? "none", entry.newAlbumName ?? "none")
        case .artistRename:
            (entry.oldArtist ?? "none", entry.newArtist ?? "none")
        }
    }

    private static func isRealChange(_ entry: ChangeLogEntry) -> Bool {
        switch entry.changeType {
        case .genreUpdate:
            entry.oldGenre != entry.newGenre
        case .yearUpdate, .yearRevert:
            entry.oldYear != entry.newYear
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

struct UpdateRunTrackResult: Identifiable, Equatable {
    let id: String
    let technicalID: String
    let title: String
    let trackNumber: Int?
    let currentGenre: String?
    let currentYear: Int?
    let releaseYear: Int?
    let trackStatus: String?
    let changes: [UpdateRunChangeSummary]
    let failureMessage: String?
    let processingStatus: TrackProcessingStatus?

    var hasChanges: Bool {
        !changes.isEmpty
    }
    var hasFailure: Bool {
        failureMessage != nil
    }

    var proposedSummary: String {
        guard !changes.isEmpty else { return "No proposed change" }
        return changes.map(\.summary).joined(separator: ", ")
    }

    var currentMetadataSummary: String {
        if !changes.isEmpty {
            let changedMetadata = changes.map(\.oldMetadataSummary)
            if !changedMetadata.isEmpty {
                return changedMetadata.joined(separator: " | ")
            }
        }

        var parts = [String]()
        if let currentYear {
            parts.append("Year \(currentYear)")
        }
        if let releaseYear, releaseYear != currentYear {
            parts.append("Release \(releaseYear)")
        }
        if let currentGenre, !currentGenre.isEmpty {
            parts.append(currentGenre)
        }
        return parts.isEmpty ? "No metadata" : parts.joined(separator: " | ")
    }
}

struct UpdateRunChangeSummary: Equatable, Hashable {
    let changeType: ChangeType
    let oldValue: String
    let newValue: String

    var summary: String {
        "\(oldValue) -> \(newValue)"
    }

    var oldMetadataSummary: String {
        switch changeType {
        case .genreUpdate:
            "Genre \(oldValue)"
        case .yearUpdate, .yearRevert:
            "Year \(oldValue)"
        case .trackCleaning:
            "Name \(oldValue)"
        case .albumCleaning:
            "Album \(oldValue)"
        case .artistRename:
            "Artist \(oldValue)"
        }
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
