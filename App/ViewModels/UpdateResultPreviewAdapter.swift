import Core
import DesignUI
import Foundation
import Services

enum UpgradeCopy {
    static let cleaningWrite = """
    Applying accepted track cleaning, album cleaning, or artist renames requires Week Pass or Pro. \
    Preview and review remain available.
    """
}

enum UpdateResultPreviewAdapter {
    static func makeSnapshot(
        from projection: FixPlanProjection,
        hasCleaningAccess: Bool,
        noticeMessage: String?,
        noticeTone: Tone
    ) -> UpdateResultSnapshot {
        let items = projection.items.map(PreviewItem.init)
        let status = makeStatus(projection.status)
        return makeSnapshot(
            items: items,
            context: PreviewContext(
                status: status,
                scopeTitle: makeScopeTitle(projection.scope),
                summary: PreviewSummary(projection: projection),
                notices: makeNotices(
                    issues: projection.operationalIssues,
                    message: noticeMessage,
                    tone: noticeTone
                ) + makeIdentityNotices(items),
                hasCleaningAccess: hasCleaningAccess,
                primaryActionLabel: applyLabel(count: projection.acceptedCount),
                secondaryActionLabel: nil
            )
        )
    }

    static func makeSnapshot(
        changes: [ProposedChange],
        scopeTitle: String,
        hasCleaningAccess: Bool,
        primaryActionLabel: String
    ) -> UpdateResultSnapshot {
        let items = changes.map(PreviewItem.init)
        return makeSnapshot(
            items: items,
            context: PreviewContext(
                status: items.isEmpty ? .empty : .ready,
                scopeTitle: scopeTitle,
                summary: PreviewSummary(items: items),
                notices: [],
                hasCleaningAccess: hasCleaningAccess,
                primaryActionLabel: primaryActionLabel,
                secondaryActionLabel: "Back"
            )
        )
    }

    private static func makeSnapshot(
        items: [PreviewItem],
        context: PreviewContext
    ) -> UpdateResultSnapshot {
        UpdateResultSnapshot(
            mode: .preview,
            status: context.status,
            title: title(for: context.status),
            subtitle: subtitle(for: context.status, itemCount: context.summary.itemCount),
            scope: context.scopeTitle,
            metrics: makeMetrics(context.summary),
            albums: makeAlbums(items),
            notices: context.notices,
            contentAccess: makeContentAccess(items, hasCleaningAccess: context.hasCleaningAccess),
            primaryActionLabel: context.primaryActionLabel,
            secondaryActionLabel: context.secondaryActionLabel
        )
    }

    private static func makeAlbums(_ items: [PreviewItem]) -> [UpdateResultAlbum] {
        var albums: [String: AlbumBucket] = [:]

        for (index, item) in items.enumerated() {
            let albumID = AlbumIdentity.key(artist: item.artist, album: item.album)
            if var album = albums[albumID] {
                album.items.append(item)
                albums[albumID] = album
            } else {
                albums[albumID] = AlbumBucket(
                    id: albumID,
                    title: "\(item.artist) — \(item.album)",
                    firstIndex: index,
                    items: [item]
                )
            }
        }

        return albums.values
            .sorted(by: compareAlbums)
            .map { album in
                UpdateResultAlbum(
                    id: album.id,
                    title: album.title,
                    tracks: makeTracks(album.items)
                )
            }
    }

    private static func makeTracks(_ items: [PreviewItem]) -> [UpdateResultTrack] {
        var tracks: [String: TrackBucket] = [:]

        for (index, item) in items.enumerated() {
            if var track = tracks[item.trackID] {
                track.items.append(item)
                tracks[item.trackID] = track
            } else {
                tracks[item.trackID] = TrackBucket(
                    id: item.trackID,
                    title: item.trackName,
                    artist: item.artist,
                    firstIndex: index,
                    items: [item]
                )
            }
        }

        return tracks.values
            .sorted { $0.firstIndex < $1.firstIndex }
            .map { track in
                UpdateResultTrack(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    state: .ready,
                    changes: track.items.map(makeChange)
                )
            }
    }

    private static func makeChange(_ item: PreviewItem) -> UpdateResultChange {
        UpdateResultChange(
            id: item.id.uuidString,
            type: makeType(item.changeType),
            oldValue: item.oldValue,
            newValue: item.newValue ?? "none",
            source: item.source.isEmpty ? nil : item.source,
            confidence: clampedConfidence(item.confidence),
            state: .proposed(makeVerdict(item.verdict))
        )
    }

    private static func makeMetrics(_ summary: PreviewSummary) -> [UpdateResultMetric] {
        var metrics = [
            metric("changes", "Changes", summary.itemCount, .accent),
            metric("accepted", "Accepted", summary.acceptedCount, .success),
            metric("rejected", "Rejected", summary.rejectedCount, .warning),
            metric("genre", "Genre", summary.genreCount, .purple),
            metric("year", "Year", summary.yearCount, .info),
            metric("track-cleaning", "Track cleaning", summary.trackCleaningCount, .teal),
            metric("album-cleaning", "Album cleaning", summary.albumCleaningCount, .teal),
            metric("artist-rename", "Artist rename", summary.artistRenameCount, .accent),
            metric("affected-tracks", "Affected tracks", summary.affectedTrackCount, .neutral),
            metric("affected-albums", "Affected albums", summary.affectedAlbumCount, .neutral),
        ]
        if let averageConfidence = summary.averageConfidence {
            metrics.append(UpdateResultMetric(
                id: "average-confidence",
                label: "Avg confidence",
                value: "\(averageConfidence)%",
                tone: .teal
            ))
        }
        return metrics
    }

    private static func metric(
        _ id: String,
        _ label: String,
        _ value: Int,
        _ tone: Tone
    ) -> UpdateResultMetric {
        UpdateResultMetric(id: id, label: label, value: value.formatted(), tone: tone)
    }

    private static func makeNotices(
        issues: [OperationalIssue],
        message: String?,
        tone: Tone
    ) -> [UpdateResultNotice] {
        var notices = issues.map { issue in
            UpdateResultNotice(
                id: issue.id,
                title: "Plan notice",
                message: issueText(issue),
                tone: .warning
            )
        }
        if let message {
            notices.append(UpdateResultNotice(
                id: "review-status",
                title: "Review status",
                message: message,
                tone: tone
            ))
        }
        return notices
    }

    private static func makeIdentityNotices(_ items: [PreviewItem]) -> [UpdateResultNotice] {
        items.compactMap { item in
            guard item.verdict == .accepted, !item.hasWriteID else { return nil }
            let message = "Proposal \(item.id.uuidString) for track \(item.trackID) cannot be applied " +
                "because its AppleScript write identity is missing."
            return UpdateResultNotice(
                id: "missing-write-id-\(item.id.uuidString)",
                title: "Write identity required",
                message: message,
                tone: .warning
            )
        }
    }

    private static func makeContentAccess(
        _ items: [PreviewItem],
        hasCleaningAccess: Bool
    ) -> ContentAccess {
        let requiresCleaningAccess = items.contains { item in
            item.verdict == .accepted && item.changeType.requiredWriteFeature == .artistAlbumCleaning
        }
        guard requiresCleaningAccess, !hasCleaningAccess else { return .available }
        return .locked(message: UpgradeCopy.cleaningWrite)
    }

    private static func makeStatus(_ status: FixPlanProjectionStatus) -> UpdateResultStatus {
        switch status {
        case .empty: .empty
        case .ready: .ready
        case .stale: .stale
        case .unavailable: .unavailable
        }
    }

    private static func makeScopeTitle(_ scope: ProcessingScopeSnapshot?) -> String {
        guard let scope else { return "Scope unavailable" }
        switch scope.source {
        case .fullLibrary:
            return "Full effective scope"
        case .testArtists:
            if scope.normalizedTestArtists.count == 1, let artist = scope.normalizedTestArtists.first {
                return "Test Artist: \(artist)"
            }
            return "Test Artists: \(scope.normalizedTestArtists.count)"
        }
    }

    private static func makeType(_ type: Core.ChangeType) -> DesignUI.ChangeType {
        switch type {
        case .genreUpdate: .genre
        case .yearUpdate: .year
        case .trackCleaning: .track
        case .albumCleaning: .album
        case .artistRename: .artist
        case .yearRevert: .revert
        }
    }

    private static func makeVerdict(_ verdict: FixPlanItemVerdict) -> UpdateResultVerdict {
        switch verdict {
        case .accepted: .accepted
        case .rejected: .rejected
        }
    }

    private static func title(for status: UpdateResultStatus) -> String {
        switch status {
        case .ready, .stale: "Review changes"
        case .empty: "No proposed changes"
        case .unavailable: "Fix plan unavailable"
        case .completed, .completedWithFailures: "Review changes"
        }
    }

    private static func subtitle(for status: UpdateResultStatus, itemCount: Int) -> String {
        switch status {
        case .ready: "\(itemCount.formatted()) candidate fixes · preview mode"
        case .stale: "\(itemCount.formatted()) candidate fixes · stale plan"
        case .empty: "No reviewable changes are available."
        case .unavailable: "The latest preview plan could not be loaded."
        case .completed, .completedWithFailures: "\(itemCount.formatted()) candidate fixes"
        }
    }

    private static func applyLabel(count: Int) -> String {
        "Apply \(count.formatted()) \(count == 1 ? "change" : "changes")"
    }

    private static func issueText(_ issue: OperationalIssue) -> String {
        guard let detail = issue.technicalDetail else { return issue.summary }
        return "\(issue.summary): \(detail)"
    }

    private static func clampedConfidence(_ confidence: Int) -> Double {
        Double(min(max(confidence, 0), 100)) / 100
    }

    private static func compareAlbums(_ left: AlbumBucket, _ right: AlbumBucket) -> Bool {
        let comparison = left.title.localizedCaseInsensitiveCompare(right.title)
        if comparison == .orderedSame {
            return left.firstIndex < right.firstIndex
        }
        return comparison == .orderedAscending
    }
}

private struct PreviewItem {
    let id: UUID
    let trackID: String
    let trackName: String
    let artist: String
    let album: String
    let changeType: Core.ChangeType
    let oldValue: String?
    let newValue: String?
    let confidence: Int
    let source: String
    let verdict: FixPlanItemVerdict
    let hasWriteID: Bool

    init(_ item: FixPlanProjectionItem) {
        id = item.id
        trackID = item.trackID
        trackName = item.trackName
        artist = item.artist
        album = item.album
        changeType = item.changeType
        oldValue = item.oldValue
        newValue = item.newValue
        confidence = item.confidence
        source = item.source
        verdict = item.verdict
        hasWriteID = item.hasWriteID
    }

    init(_ change: ProposedChange) {
        id = change.id
        trackID = change.track.id
        trackName = change.track.name
        artist = change.track.artist
        album = change.track.album
        changeType = change.changeType
        oldValue = change.oldValue
        newValue = change.newValue
        confidence = change.confidence
        source = change.source
        verdict = change.isAccepted ? .accepted : .rejected
        hasWriteID = change.track.appleScriptID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private struct PreviewContext {
    let status: UpdateResultStatus
    let scopeTitle: String
    let summary: PreviewSummary
    let notices: [UpdateResultNotice]
    let hasCleaningAccess: Bool
    let primaryActionLabel: String
    let secondaryActionLabel: String?
}

private struct PreviewSummary {
    let itemCount: Int
    let acceptedCount: Int
    let rejectedCount: Int
    let genreCount: Int
    let yearCount: Int
    let trackCleaningCount: Int
    let albumCleaningCount: Int
    let artistRenameCount: Int
    let affectedTrackCount: Int
    let affectedAlbumCount: Int
    let averageConfidence: Int?

    init(projection: FixPlanProjection) {
        itemCount = projection.itemCount
        acceptedCount = projection.acceptedCount
        rejectedCount = projection.rejectedCount
        genreCount = projection.genreCount
        yearCount = projection.yearCount
        trackCleaningCount = projection.trackCleaningCount
        albumCleaningCount = projection.albumCleaningCount
        artistRenameCount = projection.artistRenameCount
        affectedTrackCount = projection.affectedTrackCount
        affectedAlbumCount = projection.affectedAlbumCount
        averageConfidence = projection.averageConfidence
    }

    init(items: [PreviewItem]) {
        itemCount = items.count
        acceptedCount = items.count(where: { $0.verdict == .accepted })
        rejectedCount = itemCount - acceptedCount
        genreCount = items.count(where: { $0.changeType == .genreUpdate })
        yearCount = items.count(where: { $0.changeType == .yearUpdate || $0.changeType == .yearRevert })
        trackCleaningCount = items.count(where: { $0.changeType == .trackCleaning })
        albumCleaningCount = items.count(where: { $0.changeType == .albumCleaning })
        artistRenameCount = items.count(where: { $0.changeType == .artistRename })
        affectedTrackCount = Set(items.map(\.trackID)).count
        affectedAlbumCount = Set(items.map { AlbumIdentity.key(artist: $0.artist, album: $0.album) }).count
        averageConfidence = Self.averageConfidence(items)
    }

    private static func averageConfidence(_ items: [PreviewItem]) -> Int? {
        guard !items.isEmpty else { return nil }
        let total = items.reduce(0) { $0 + $1.confidence }
        let average = Int((Double(total) / Double(items.count)).rounded())
        return min(max(average, 0), 100)
    }
}

private struct AlbumBucket {
    let id: String
    let title: String
    let firstIndex: Int
    var items: [PreviewItem]
}

private struct TrackBucket {
    let id: String
    let title: String
    let artist: String
    let firstIndex: Int
    var items: [PreviewItem]
}
