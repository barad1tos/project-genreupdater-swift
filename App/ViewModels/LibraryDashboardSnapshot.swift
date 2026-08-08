import Core
import Foundation
import Services

enum LibraryLoadError: Equatable {
    case permissionDenied
    case restricted
    case failed(String)

    static func make(from error: Error) -> Self {
        guard let musicLibraryError = error as? MusicLibraryError else {
            return .failed(error.localizedDescription)
        }

        switch musicLibraryError {
        case .authorizationDenied:
            return .permissionDenied
        case .authorizationRestricted:
            return .restricted
        case .fetchFailed, .musicAppNotAvailable:
            return .failed(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "Music library permission denied"
        case .restricted:
            "Music library access is restricted on this device"
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
    let isProtectedFileCountKnown: Bool
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

    var allowsReviewActions: Bool {
        guard case .ready = scanState else { return false }
        if case .writing = writeState {
            return false
        }
        return true
    }

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
        let counts = ActivityHealthCounts(
            totalTracks: persistedMetrics.totalTracks,
            tracksWithGenre: persistedMetrics.tracksWithGenre,
            tracksWithYear: persistedMetrics.tracksWithYear,
            tracksWithBoth: persistedMetrics.tracksWithBoth,
            protectedFileCount: persistedMetrics.protectedFileCount ?? 0,
            isProtectedFileCountKnown: persistedMetrics.protectedFileCount != nil
        )
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
        let counts = ActivityHealthCounts.make(from: tracks)
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

    /// Numeric truth delegates to the shared Services formula (D8): this
    /// snapshot keeps only the App-side scan/write state machine.
    private static func make(
        counts: ActivityHealthCounts,
        scanState: LibraryScanState,
        isDryRun: Bool,
        workflow: WorkflowDashboardState
    ) -> Self {
        let writeState = makeWriteState(isDryRun: isDryRun, workflow: workflow)
        let facts = ActivityHealthFacts.make(
            counts: counts,
            readyUpdateCount: workflow.acceptedChangeCount,
            failedWriteCount: workflow.failedWriteCount
        )

        return Self(
            totalTracks: facts.counts.totalTracks,
            tracksWithGenre: facts.counts.tracksWithGenre,
            tracksWithYear: facts.counts.tracksWithYear,
            tracksWithBoth: facts.counts.tracksWithBoth,
            missingGenreCount: facts.missingGenreCount,
            missingYearCount: facts.missingYearCount,
            protectedFileCount: facts.counts.protectedFileCount,
            isProtectedFileCountKnown: facts.counts.isProtectedFileCountKnown,
            readyUpdateCount: facts.readyUpdateCount,
            genreCoverageRatio: facts.genreCoverageRatio,
            yearCoverageRatio: facts.yearCoverageRatio,
            consistencyCoverageRatio: facts.consistencyCoverageRatio,
            editableCoverageRatio: facts.editableCoverageRatio,
            healthScore: facts.healthScore,
            healthPercentage: facts.healthPercentage,
            scanState: scanState,
            writeState: writeState,
            primaryStatusText: makePrimaryStatusText(
                scanState: scanState,
                writeState: writeState,
                readyUpdateCount: facts.readyUpdateCount
            ),
            primaryActionTitle: makePrimaryActionTitle(scanState: scanState, writeState: writeState),
            issues: DashboardSnapshotContent.makeIssues(facts: facts, failedWriteCount: workflow.failedWriteCount),
            coverageBuckets: DashboardSnapshotContent.makeCoverageBuckets(facts: facts),
            recentActivity: DashboardSnapshotContent.makeRecentActivity(
                totalTracks: facts.counts.totalTracks,
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
            case .restricted:
                return .failed(loadError.message)
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
}

private enum DashboardSnapshotContent {
    static func makeIssues(facts: ActivityHealthFacts, failedWriteCount: Int) -> [DashboardIssue] {
        [
            DashboardIssue(
                id: "missing-genres",
                title: "Missing genres",
                count: facts.missingGenreCount,
                severity: missingMetadataSeverity(facts.missingGenreCount)
            ),
            DashboardIssue(
                id: "missing-years",
                title: "Missing years",
                count: facts.missingYearCount,
                severity: missingMetadataSeverity(facts.missingYearCount)
            ),
            DashboardIssue(
                id: "protected-files",
                title: facts.counts.isProtectedFileCountKnown ? "Protected files" : "Protected files unknown",
                count: facts.counts.protectedFileCount,
                severity: protectedFileSeverity(counts: facts.counts)
            ),
            DashboardIssue(
                id: "write-errors",
                title: "Write errors",
                count: failedWriteCount,
                severity: failedWriteCount > 0 ? .critical : .info
            ),
        ]
    }

    static func makeCoverageBuckets(facts: ActivityHealthFacts) -> [DashboardCoverageBucket] {
        [
            DashboardCoverageBucket(id: "genre", title: "Genre coverage", ratio: facts.genreCoverageRatio),
            DashboardCoverageBucket(id: "year", title: "Year coverage", ratio: facts.yearCoverageRatio),
            DashboardCoverageBucket(id: "consistency", title: "Consistency", ratio: facts.consistencyCoverageRatio),
            DashboardCoverageBucket(
                id: "editable",
                title: facts.counts.isProtectedFileCountKnown ? "Editable files" : "Editable files unknown",
                ratio: facts.editableCoverageRatio
            ),
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

    private static func protectedFileSeverity(counts: ActivityHealthCounts) -> DashboardIssueSeverity {
        if counts.protectedFileCount > 0 {
            return .critical
        }
        return counts.isProtectedFileCountKnown ? .info : .warning
    }
}
