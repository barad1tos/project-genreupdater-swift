import Core
import Services

struct UpdateRunReport: Equatable {
    let scopeTitle: String
    let changedEntries: [ChangeLogEntry]
    let albumGroups: [UpdateRunAlbumGroup]
    let albumResults: [UpdateRunAlbumResult]
    let changeBreakdown: [UpdateRunChangeBreakdown]
    let failures: [UpdateRunFailure]
    let skippedCount: Int
    let scannedTrackCount: Int

    init(
        result: BatchUpdateResult?,
        completedEntries: [ChangeLogEntry],
        trackStatuses: [String: TrackProcessingStatus],
        tracks: [Track],
        testArtists: [String]
    ) {
        let entries = (result?.entries ?? completedEntries).filter(Self.isRealChange)
        let trackLookup = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let failureItems = Self.makeFailures(
            result: result,
            trackStatuses: trackStatuses,
            trackLookup: trackLookup
        )
        changedEntries = entries
        albumGroups = Self.makeAlbumGroups(from: entries)
        changeBreakdown = Self.makeChangeBreakdown(from: entries)
        failures = failureItems
        albumResults = Self.makeAlbumResults(
            entries: entries,
            failures: failureItems,
            tracks: tracks,
            trackStatuses: trackStatuses,
            trackLookup: trackLookup
        )
        skippedCount = trackStatuses.values.count { status in
            if case .skipped = status { return true }
            return false
        }
        scannedTrackCount = trackStatuses.isEmpty ? tracks.count : trackStatuses.count
        scopeTitle = Self.makeScopeTitle(testArtists: testArtists)
    }

    var changedTrackCount: Int {
        Set(changedEntries.map(\.trackID)).count
    }

    var affectedAlbumCount: Int {
        albumResults.count
    }

    var affectedArtistCount: Int {
        Set(albumGroups.map(\.artist)).count
    }

    var hasFailures: Bool {
        !failures.isEmpty
    }

    var title: String {
        if hasFailures {
            return "Finished with \(failures.count.formatted()) \(Self.issueNoun(failures.count))"
        }
        return "Update Complete"
    }

    private static func makeScopeTitle(testArtists: [String]) -> String {
        let normalizedArtists = ArtistAllowList.normalized(testArtists)
        guard !normalizedArtists.isEmpty else { return "Full effective scope" }
        if normalizedArtists.count == 1, let artist = normalizedArtists.first {
            return "Test Artist: \(artist)"
        }
        return "Test Artists: \(normalizedArtists.count)"
    }

    private static func makeAlbumGroups(from entries: [ChangeLogEntry]) -> [UpdateRunAlbumGroup] {
        var buckets: [UpdateRunAlbumGroupKey: (firstIndex: Int, entries: [ChangeLogEntry])] = [:]

        for (index, entry) in entries.enumerated() {
            let values = valuePair(for: entry)
            let key = UpdateRunAlbumGroupKey(
                artist: entry.artist,
                album: entry.albumName,
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
            .sorted { left, right in
                if left.sortIndex == right.sortIndex {
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
                return left.sortIndex < right.sortIndex
            }
    }

    private static func makeFailures(
        result: BatchUpdateResult?,
        trackStatuses: [String: TrackProcessingStatus],
        trackLookup: [String: Track]
    ) -> [UpdateRunFailure] {
        var failureMessages = failureMessages(from: result)

        for (trackID, status) in trackStatuses {
            if case let .failed(message) = status {
                failureMessages[trackID] = message
            }
        }

        return failureMessages
            .map { trackID, message in
                let track = trackLookup[trackID]
                return UpdateRunFailure(
                    id: trackID,
                    title: track?.name ?? "Unknown track",
                    subtitle: track.map { "\($0.artist) - \($0.album)" } ?? "Track ID: \(trackID)",
                    message: message,
                    technicalID: trackID,
                    hasKnownTrack: track != nil,
                    artist: track?.effectiveArtist ?? "Unknown artist",
                    album: track?.album ?? "Unknown album"
                )
            }
            .sorted { left, right in
                left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
    }

    private static func makeChangeBreakdown(from entries: [ChangeLogEntry]) -> [UpdateRunChangeBreakdown] {
        Dictionary(grouping: entries, by: \.changeType)
            .map { changeType, entries in
                UpdateRunChangeBreakdown(
                    changeType: changeType,
                    changeCount: entries.count,
                    trackCount: Set(entries.map(\.trackID)).count,
                    albumCount: Set(entries.map { [$0.artist, $0.albumName].joined(separator: "\u{1F}") }).count
                )
            }
            .sorted { left, right in
                left.changeType.displayLabel
                    .localizedStandardCompare(right.changeType.displayLabel) == .orderedAscending
            }
    }

    private static func makeAlbumResults(
        entries: [ChangeLogEntry],
        failures: [UpdateRunFailure],
        tracks: [Track],
        trackStatuses: [String: TrackProcessingStatus],
        trackLookup: [String: Track]
    ) -> [UpdateRunAlbumResult] {
        let changesByTrackID = Dictionary(grouping: entries, by: \.trackID)
        let failuresByTrackID = Dictionary(uniqueKeysWithValues: failures.map { ($0.id, $0) })
        let albumKeys = albumResultKeys(
            entries: entries,
            failures: failures,
            tracks: tracks,
            changesByTrackID: changesByTrackID,
            failuresByTrackID: failuresByTrackID
        )

        return albumKeys.map { key in
            let albumTracks = tracks
                .filter { track in
                    albumIdentity(for: track) == key
                }
                .sorted(by: trackSort)
            let fallbackRows = fallbackRowsForMissingTracks(
                key: key,
                entries: entries,
                failures: failures,
                trackLookup: trackLookup
            )
            let trackRows = albumTracks.map { track in
                makeTrackResult(
                    track: track,
                    changes: changesByTrackID[track.id] ?? [],
                    failure: failuresByTrackID[track.id],
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
        tracks: [Track],
        changesByTrackID: [String: [ChangeLogEntry]],
        failuresByTrackID: [String: UpdateRunFailure]
    ) -> Set<UpdateRunAlbumIdentity> {
        var keys = Set<UpdateRunAlbumIdentity>()
        for entry in entries {
            keys.insert(UpdateRunAlbumIdentity(artist: entry.artist, album: entry.albumName))
        }
        for failure in failures {
            keys.insert(UpdateRunAlbumIdentity(artist: failure.artist, album: failure.album))
        }
        for track in tracks where changesByTrackID[track.id] != nil || failuresByTrackID[track.id] != nil {
            keys.insert(albumIdentity(for: track))
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
                    && UpdateRunAlbumIdentity(artist: entry.artist, album: entry.albumName) == key
            }
            .map { entry in
                makeFallbackTrackResult(entry: entry)
            }
        let missingFailureRows = failures
            .filter { failure in
                trackLookup[failure.id] == nil
                    && failure.artist == key.artist
                    && failure.album == key.album
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
        failure: UpdateRunFailure?,
        status: TrackProcessingStatus?
    ) -> UpdateRunTrackResult {
        UpdateRunTrackResult(
            id: track.id,
            title: track.name,
            trackNumber: track.originalPosition,
            currentGenre: track.genre,
            currentYear: track.year,
            releaseYear: track.releaseYear,
            trackStatus: track.trackStatus,
            changes: changes.map(makeChangeSummary),
            failureMessage: failure?.message,
            processingStatus: status
        )
    }

    private static func makeFallbackTrackResult(entry: ChangeLogEntry) -> UpdateRunTrackResult {
        UpdateRunTrackResult(
            id: entry.trackID,
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

    private static func albumIdentity(for track: Track) -> UpdateRunAlbumIdentity {
        UpdateRunAlbumIdentity(artist: track.effectiveArtist, album: track.album)
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

    private static func failureMessages(from result: BatchUpdateResult?) -> [String: String] {
        guard let result else { return [:] }
        var messages: [String: String] = [:]
        for (index, trackID) in result.failedTrackIDs.enumerated() {
            messages[trackID] = result.errorDescriptions[safe: index]
                ?? "No failure details were captured for this run."
        }
        return messages
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

    var plainTextSummary: String {
        var lines = [
            title,
            "Scope: \(scopeTitle)",
            "Tracks scanned: \(scannedTrackCount)",
            "Track changes: \(changedEntries.count)",
            "Tracks changed: \(changedTrackCount)",
            "Albums affected: \(affectedAlbumCount)",
            "Failures: \(failures.count)",
            "",
        ]

        appendNoChangesSummary(to: &lines)
        appendFailures(to: &lines)
        appendChangeBreakdown(to: &lines)
        appendAlbumGroups(to: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendNoChangesSummary(to lines: inout [String]) {
        guard changedEntries.isEmpty else { return }

        lines.append("No changes were made during this run.")
        lines.append("")
    }

    private func appendFailures(to lines: inout [String]) {
        guard !failures.isEmpty else { return }

        lines.append("Needs Attention")
        for failure in failures {
            lines.append("- \(failure.title) (\(failure.subtitle)): \(failure.message)")
        }
        lines.append("")
    }

    private func appendChangeBreakdown(to lines: inout [String]) {
        guard !changeBreakdown.isEmpty else { return }

        lines.append("Change Breakdown")
        for item in changeBreakdown {
            lines.append("- \(item.changeType.displayLabel): \(item.summary)")
        }
        lines.append("")
    }

    private func appendAlbumGroups(to lines: inout [String]) {
        guard !albumGroups.isEmpty else { return }

        lines.append("Changed Albums")
        for group in albumGroups {
            lines.append("- \(group.title): \(group.changeType.displayLabel) \(group.changeSummary)")
            for entry in group.entries {
                lines.append("  - \(entry.trackName)")
            }
        }
    }
}

struct UpdateRunChangeBreakdown: Equatable {
    let changeType: ChangeType
    let changeCount: Int
    let trackCount: Int
    let albumCount: Int

    var summary: String {
        [
            "\(changeCount.formatted()) \(Self.noun("change", count: changeCount))",
            "\(trackCount.formatted()) \(Self.noun("track", count: trackCount))",
            "\(albumCount.formatted()) \(Self.noun("album", count: albumCount))",
        ].joined(separator: ", ")
    }

    private static func noun(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
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
        tracks.count { $0.hasFailure }
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

private struct UpdateRunAlbumIdentity: Hashable {
    let artist: String
    let album: String
}

private struct UpdateRunAlbumGroupKey: Hashable {
    let artist: String
    let album: String
    let changeType: ChangeType
    let oldValue: String
    let newValue: String
}
