// swiftlint:disable file_length

import Core
import Foundation
import Services

enum LibraryLoadError: Equatable {
    case permissionDenied
    case failed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            "Music library permission denied"
        case let .failed(message):
            message
        }
    }
}

enum LibraryScanState: Equatable {
    case loading
    case ready(lastScanDate: Date?)
    case empty
    case permissionDenied
    case failed(String)
}

enum LibraryWriteState: Equatable {
    case dryRun
    case ready(count: Int, isDryRun: Bool)
    case writing(label: String)
    case blocked(String)
}

enum DashboardIssueSeverity: Equatable {
    case info
    case warning
    case critical
}

struct DashboardIssue: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    let severity: DashboardIssueSeverity
}

struct DashboardActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

struct DashboardCoverageBucket: Identifiable, Equatable {
    let id: String
    let title: String
    let ratio: Double
}

struct WorkflowDashboardState: Equatable {
    let proposedChangeCount: Int
    let acceptedChangeCount: Int
    let failedWriteCount: Int
    let isProcessing: Bool
    let phaseLabel: String

    static let empty = Self(
        proposedChangeCount: 0,
        acceptedChangeCount: 0,
        failedWriteCount: 0,
        isProcessing: false,
        phaseLabel: "Idle"
    )
}

struct LibraryDashboardSnapshot: Equatable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let missingGenreCount: Int
    let missingYearCount: Int
    let protectedFileCount: Int
    let readyUpdateCount: Int
    let genreCoverageRatio: Double
    let yearCoverageRatio: Double
    let consistencyCoverageRatio: Double
    let editableCoverageRatio: Double
    let healthScore: Double
    let healthPercentage: Int
    let scanState: LibraryScanState
    let writeState: LibraryWriteState
    let primaryStatusText: String
    let primaryActionTitle: String
    let issues: [DashboardIssue]
    let coverageBuckets: [DashboardCoverageBucket]
    let recentActivity: [DashboardActivity]

    static let empty = make(
        tracks: [],
        lastScanDate: nil,
        isLoading: false,
        loadError: nil,
        isDryRun: true,
        workflow: .empty
    )

    static func make(
        persistedMetrics: PersistedMetricsSnapshot,
        isLoading: Bool = false,
        loadError: LibraryLoadError? = nil,
        isDryRun: Bool,
        workflow: WorkflowDashboardState
    ) -> Self {
        let counts = TrackDashboardCounts.make(from: persistedMetrics)
        let scanState = makeScanState(
            hasLibraryContent: counts.totalTracks > 0,
            lastScanDate: persistedMetrics.timestamp,
            isLoading: isLoading,
            loadError: loadError
        )

        return make(
            counts: counts,
            scanState: scanState,
            isDryRun: isDryRun,
            workflow: workflow
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func make(
        tracks: [Core.Track],
        lastScanDate: Date?,
        isLoading: Bool,
        loadError: LibraryLoadError?,
        isDryRun: Bool,
        workflow: WorkflowDashboardState
    ) -> Self {
        let counts = TrackDashboardCounts.make(from: tracks)
        let scanState = makeScanState(
            hasLibraryContent: !tracks.isEmpty,
            lastScanDate: lastScanDate,
            isLoading: isLoading,
            loadError: loadError
        )

        return make(
            counts: counts,
            scanState: scanState,
            isDryRun: isDryRun,
            workflow: workflow
        )
    }

    private static func make(
        counts: TrackDashboardCounts,
        scanState: LibraryScanState,
        isDryRun: Bool,
        workflow: WorkflowDashboardState
    ) -> Self {
        let writeState = makeWriteState(isDryRun: isDryRun, workflow: workflow)
        let readyUpdateCount = workflow.acceptedChangeCount
        let genreCoverageRatio = ratio(counts.tracksWithGenre, of: counts.totalTracks)
        let yearCoverageRatio = ratio(counts.tracksWithYear, of: counts.totalTracks)
        let consistencyCoverageRatio = ratio(counts.tracksWithBoth, of: counts.totalTracks)
        let editableCoverageRatio = ratio(counts.totalTracks - counts.protectedFileCount, of: counts.totalTracks)
        let healthScore = makeHealthScore(
            counts: counts,
            genreCoverageRatio: genreCoverageRatio,
            yearCoverageRatio: yearCoverageRatio,
            consistencyCoverageRatio: consistencyCoverageRatio,
            failedWriteCount: workflow.failedWriteCount
        )

        return Self(
            totalTracks: counts.totalTracks,
            tracksWithGenre: counts.tracksWithGenre,
            tracksWithYear: counts.tracksWithYear,
            tracksWithBoth: counts.tracksWithBoth,
            missingGenreCount: counts.missingGenreCount,
            missingYearCount: counts.missingYearCount,
            protectedFileCount: counts.protectedFileCount,
            readyUpdateCount: readyUpdateCount,
            genreCoverageRatio: genreCoverageRatio,
            yearCoverageRatio: yearCoverageRatio,
            consistencyCoverageRatio: consistencyCoverageRatio,
            editableCoverageRatio: editableCoverageRatio,
            healthScore: healthScore,
            healthPercentage: Int((healthScore * 100).rounded()),
            scanState: scanState,
            writeState: writeState,
            primaryStatusText: makePrimaryStatusText(
                scanState: scanState,
                writeState: writeState,
                readyUpdateCount: readyUpdateCount
            ),
            primaryActionTitle: makePrimaryActionTitle(scanState: scanState, writeState: writeState),
            issues: DashboardSnapshotContent.makeIssues(counts: counts, failedWriteCount: workflow.failedWriteCount),
            coverageBuckets: DashboardSnapshotContent.makeCoverageBuckets(
                genreCoverageRatio: genreCoverageRatio,
                yearCoverageRatio: yearCoverageRatio,
                consistencyCoverageRatio: consistencyCoverageRatio,
                editableCoverageRatio: editableCoverageRatio
            ),
            recentActivity: DashboardSnapshotContent.makeRecentActivity(
                totalTracks: counts.totalTracks,
                scanState: scanState,
                workflow: workflow
            )
        )
    }

    private static func makeScanState(
        hasLibraryContent: Bool,
        lastScanDate: Date?,
        isLoading: Bool,
        loadError: LibraryLoadError?
    ) -> LibraryScanState {
        if let loadError {
            switch loadError {
            case .permissionDenied:
                return .permissionDenied
            case let .failed(message):
                return .failed(message)
            }
        }

        if isLoading {
            return .loading
        }

        if !hasLibraryContent {
            return .empty
        }

        return .ready(lastScanDate: lastScanDate)
    }

    private static func makeWriteState(isDryRun: Bool, workflow: WorkflowDashboardState) -> LibraryWriteState {
        if workflow.isProcessing {
            return .writing(label: workflow.phaseLabel)
        }

        if workflow.failedWriteCount > 0 {
            return .blocked("\(workflow.failedWriteCount) write errors")
        }

        if workflow.acceptedChangeCount > 0 {
            return .ready(count: workflow.acceptedChangeCount, isDryRun: isDryRun)
        }

        if isDryRun {
            return .dryRun
        }

        return .ready(count: 0, isDryRun: false)
    }

    private static func makeHealthScore(
        counts: TrackDashboardCounts,
        genreCoverageRatio: Double,
        yearCoverageRatio: Double,
        consistencyCoverageRatio: Double,
        failedWriteCount: Int
    ) -> Double {
        guard counts.totalTracks > 0 else { return 0 }

        let coverageScore =
            genreCoverageRatio * DashboardHealthPolicy.genreCoverageWeight
                + yearCoverageRatio * DashboardHealthPolicy.yearCoverageWeight
                + consistencyCoverageRatio * DashboardHealthPolicy.consistencyCoverageWeight
        let protectedPenalty = ratio(counts.protectedFileCount, of: counts.totalTracks)
            * DashboardHealthPolicy.protectedFilePenaltyWeight
        let failedWritePenalty = min(
            ratio(failedWriteCount, of: counts.totalTracks) * DashboardHealthPolicy.failedWritePenaltyWeight,
            DashboardHealthPolicy.failedWritePenaltyCap
        )

        return clamp(coverageScore - protectedPenalty - failedWritePenalty)
    }

    private static func makePrimaryStatusText(
        scanState: LibraryScanState,
        writeState: LibraryWriteState,
        readyUpdateCount: Int
    ) -> String {
        switch scanState {
        case .loading:
            return "Scanning Music library"
        case .permissionDenied:
            return LibraryLoadError.permissionDenied.message
        case let .failed(message):
            return message
        case .empty:
            return "No tracks found"
        case .ready:
            break
        }

        if case let .blocked(message) = writeState {
            return message
        }

        if readyUpdateCount > 0 {
            return "\(readyUpdateCount) updates ready"
        }

        return "Library ready"
    }

    private static func makePrimaryActionTitle(
        scanState: LibraryScanState,
        writeState: LibraryWriteState
    ) -> String {
        switch scanState {
        case .permissionDenied:
            return "Grant access"
        case .failed:
            return "Retry scan"
        default:
            break
        }

        if case .writing = writeState {
            return "Writing updates"
        }

        if case .blocked = writeState {
            return "Review errors"
        }

        switch scanState {
        case .loading:
            return "Scanning..."
        case .permissionDenied:
            return "Grant access"
        case .failed:
            return "Retry scan"
        case .empty:
            return "Scan library"
        case .ready:
            return "Review changes"
        }
    }

    private static func ratio(_ count: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return clamp(Double(count) / Double(total))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private enum DashboardSnapshotContent {
    static func makeIssues(counts: TrackDashboardCounts, failedWriteCount: Int) -> [DashboardIssue] {
        [
            DashboardIssue(
                id: "missing-genres",
                title: "Missing genres",
                count: counts.missingGenreCount,
                severity: missingMetadataSeverity(counts.missingGenreCount)
            ),
            DashboardIssue(
                id: "missing-years",
                title: "Missing years",
                count: counts.missingYearCount,
                severity: missingMetadataSeverity(counts.missingYearCount)
            ),
            DashboardIssue(
                id: "protected-files",
                title: "Protected files",
                count: counts.protectedFileCount,
                severity: counts.protectedFileCount > 0 ? .critical : .info
            ),
            DashboardIssue(
                id: "write-errors",
                title: "Write errors",
                count: failedWriteCount,
                severity: failedWriteCount > 0 ? .critical : .info
            ),
        ]
    }

    static func makeCoverageBuckets(
        genreCoverageRatio: Double,
        yearCoverageRatio: Double,
        consistencyCoverageRatio: Double,
        editableCoverageRatio: Double
    ) -> [DashboardCoverageBucket] {
        [
            DashboardCoverageBucket(id: "genre", title: "Genre coverage", ratio: genreCoverageRatio),
            DashboardCoverageBucket(id: "year", title: "Year coverage", ratio: yearCoverageRatio),
            DashboardCoverageBucket(id: "consistency", title: "Consistency", ratio: consistencyCoverageRatio),
            DashboardCoverageBucket(id: "editable", title: "Editable files", ratio: editableCoverageRatio),
        ]
    }

    static func makeRecentActivity(
        totalTracks: Int,
        scanState: LibraryScanState,
        workflow: WorkflowDashboardState
    ) -> [DashboardActivity] {
        var activity: [DashboardActivity] = []

        switch scanState {
        case .ready:
            activity.append(
                DashboardActivity(
                    id: "scan",
                    title: "Library scan",
                    detail: "\(totalTracks) tracks analyzed"
                )
            )
        case .loading:
            activity.append(DashboardActivity(id: "scan", title: "Library scan", detail: "Scanning in progress"))
        case .empty:
            activity.append(DashboardActivity(id: "scan", title: "Library scan", detail: "No tracks found"))
        case .permissionDenied:
            activity.append(DashboardActivity(
                id: "scan",
                title: "Library scan",
                detail: LibraryLoadError.permissionDenied.message
            ))
        case let .failed(message):
            activity.append(DashboardActivity(id: "scan", title: "Library scan", detail: message))
        }

        if workflow.failedWriteCount > 0 {
            activity.append(
                DashboardActivity(
                    id: "write-errors",
                    title: "Write errors",
                    detail: "\(workflow.failedWriteCount) writes failed"
                )
            )
        } else if workflow.acceptedChangeCount > 0 {
            activity.append(
                DashboardActivity(
                    id: "workflow",
                    title: "Workflow",
                    detail: "\(workflow.acceptedChangeCount) accepted updates"
                )
            )
        } else if workflow.proposedChangeCount > 0 {
            activity.append(
                DashboardActivity(
                    id: "workflow",
                    title: "Workflow",
                    detail: "\(workflow.proposedChangeCount) proposed updates"
                )
            )
        }

        return activity
    }

    private static func missingMetadataSeverity(_ count: Int) -> DashboardIssueSeverity {
        count > 0 ? .warning : .info
    }
}

private enum DashboardHealthPolicy {
    static let genreCoverageWeight = 0.35
    static let yearCoverageWeight = 0.35
    static let consistencyCoverageWeight = 0.30
    static let protectedFilePenaltyWeight = 0.25
    static let failedWritePenaltyWeight = 2.0
    static let failedWritePenaltyCap = 0.40
}

private struct TrackDashboardCounts: Equatable {
    let totalTracks: Int
    let tracksWithGenre: Int
    let tracksWithYear: Int
    let tracksWithBoth: Int
    let missingGenreCount: Int
    let missingYearCount: Int
    let protectedFileCount: Int

    static func make(from tracks: [Core.Track]) -> Self {
        var tracksWithGenre = 0
        var tracksWithYear = 0
        var tracksWithBoth = 0
        var protectedFileCount = 0

        for track in tracks {
            let hasGenre = hasPresentGenre(track.genre)
            let hasYear = track.year != nil

            if hasGenre {
                tracksWithGenre += 1
            }

            if hasYear {
                tracksWithYear += 1
            }

            if hasGenre, hasYear {
                tracksWithBoth += 1
            }

            if !track.canEdit {
                protectedFileCount += 1
            }
        }

        return Self(
            totalTracks: tracks.count,
            tracksWithGenre: tracksWithGenre,
            tracksWithYear: tracksWithYear,
            tracksWithBoth: tracksWithBoth,
            missingGenreCount: tracks.count - tracksWithGenre,
            missingYearCount: tracks.count - tracksWithYear,
            protectedFileCount: protectedFileCount
        )
    }

    static func make(from persistedMetrics: PersistedMetricsSnapshot) -> Self {
        Self(
            totalTracks: persistedMetrics.totalTracks,
            tracksWithGenre: persistedMetrics.tracksWithGenre,
            tracksWithYear: persistedMetrics.tracksWithYear,
            tracksWithBoth: persistedMetrics.tracksWithBoth,
            missingGenreCount: persistedMetrics.tracksNeedingGenre,
            missingYearCount: persistedMetrics.tracksNeedingYear,
            protectedFileCount: 0
        )
    }

    private static func hasPresentGenre(_ genre: String?) -> Bool {
        guard let genre else { return false }
        return !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
