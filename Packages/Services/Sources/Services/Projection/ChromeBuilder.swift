import Core
import Foundation

/// Raw facts the app layer snapshots for chrome assembly. Every field is a
/// probed truth or an immutable snapshot — the builder never reads live
/// mutable state (ADR 0020 for scope; analysis D7/D9).
public struct ChromeInput: Sendable {
    public let lifecycle: RunLifecycleSnapshot?
    public let hasUnresolvedWriteRecovery: Bool
    public let recoveryRunID: RunID?
    public let isPreviewMode: Bool
    public let isAutoSyncRunning: Bool
    public let isIncrementalDue: Bool?
    public let physicalTrackCount: Int?
    public let scope: ProcessingScopeSnapshot?
    public let permissions: ChromePermissions
    public let settingsSaveErrorMessage: String?
    public let settingsLoadFailed: Bool
    public let isRunServiceAvailable: Bool
    public let hasReviewableFixPlan: Bool

    public init(
        lifecycle: RunLifecycleSnapshot?,
        hasUnresolvedWriteRecovery: Bool,
        recoveryRunID: RunID?,
        isPreviewMode: Bool,
        isAutoSyncRunning: Bool,
        isIncrementalDue: Bool?,
        physicalTrackCount: Int?,
        scope: ProcessingScopeSnapshot?,
        permissions: ChromePermissions,
        settingsSaveErrorMessage: String?,
        settingsLoadFailed: Bool,
        isRunServiceAvailable: Bool,
        hasReviewableFixPlan: Bool
    ) {
        self.lifecycle = lifecycle
        self.hasUnresolvedWriteRecovery = hasUnresolvedWriteRecovery
        self.recoveryRunID = recoveryRunID
        self.isPreviewMode = isPreviewMode
        self.isAutoSyncRunning = isAutoSyncRunning
        self.isIncrementalDue = isIncrementalDue
        self.physicalTrackCount = physicalTrackCount
        self.scope = scope
        self.permissions = permissions
        self.settingsSaveErrorMessage = settingsSaveErrorMessage
        self.settingsLoadFailed = settingsLoadFailed
        self.isRunServiceAvailable = isRunServiceAvailable
        self.hasReviewableFixPlan = hasReviewableFixPlan
    }
}

/// Assembles the shared shell truth (ADR 0012) from probed facts. Pure and
/// synchronous so every rule is a pinned truth table.
public enum ChromeBuilder {
    public static func makeProjection(input: ChromeInput) -> ChromeProjection {
        let hold = makeRecoveryHold(input: input)
        return ChromeProjection(
            revision: .initial,
            shellTitle: "Genre Updater",
            shellSubtitle: nil,
            syncStatus: makeSyncStatus(input: input, hold: hold),
            physicalTrackCount: input.physicalTrackCount,
            effectiveScope: makeScope(input: input),
            processingModeLabel: input.isPreviewMode ? "Preview" : "Auto-fix",
            automationState: makeAutomationState(input: input, hold: hold),
            recoveryHold: hold,
            permissions: input.permissions,
            commands: makeCommands(input: input, hold: hold),
            operationalIssues: makeIssues(input: input)
        )
    }

    private static func makeRecoveryHold(input: ChromeInput) -> ChromeRecoveryHold? {
        guard input.hasUnresolvedWriteRecovery else { return nil }
        return ChromeRecoveryHold(blocksWrites: true, runID: input.recoveryRunID)
    }

    private static func makeSyncStatus(input: ChromeInput, hold: ChromeRecoveryHold?) -> ChromeSyncStatus {
        let isRunActive = input.lifecycle?.isActive == true
        guard let state = input.lifecycle?.state else {
            let text = hold == nil ? "Idle" : "Recovery needed"
            return ChromeSyncStatus(
                text: text,
                severity: hold == nil ? .nominal : .blocked,
                isRunActive: false
            )
        }
        let (text, severity) = syncLine(for: state, hold: hold)
        return ChromeSyncStatus(text: text, severity: severity, isRunActive: isRunActive)
    }

    /// Keep this switch exhaustive so adding a RunLifecycleState requires a chrome decision.
    private static func syncLine(
        for state: RunLifecycleState,
        hold: ChromeRecoveryHold?
    ) -> (String, ChromeStatusSeverity) {
        switch state {
        case .created, .queued, .syncingLibrary, .analyzingDelta, .planningFixes:
            ("Running", .nominal)
        case .awaitingReview:
            ("Awaiting review", .attention)
        case .writing, .verifying, .reporting:
            ("Writing", .nominal)
        case .completed:
            hold == nil ? ("Up to date", .nominal) : ("Recovery needed", .blocked)
        case .completedNoOp:
            hold == nil ? ("Checked — nothing to do", .nominal) : ("Recovery needed", .blocked)
        case .failed:
            ("Sync failed", .attention)
        case .cancelled:
            hold == nil ? ("Cancelled", .nominal) : ("Recovery needed", .blocked)
        case .blocked:
            ("Blocked", .blocked)
        case .recoverable, .recovering:
            ("Recovery needed", .blocked)
        }
    }

    private static func makeScope(input: ChromeInput) -> ChromeScopeSummary? {
        guard let scope = input.scope else { return nil }
        let detail: String? = if let trackCount = scope.knownTrackCount {
            trackCount == 1 ? "1 known track" : "\(trackCount.formatted()) known tracks"
        } else {
            nil
        }
        return ChromeScopeSummary(
            sourceLabel: ReportsRunLabels.scopeSourceLabel(for: scope),
            detailLabel: detail,
            isNarrowedFromPhysical: scope.source == .testArtists
        )
    }

    private static func makeAutomationState(
        input: ChromeInput,
        hold: ChromeRecoveryHold?
    ) -> ChromeAutomationState {
        if input.lifecycle?.isActive == true || input.isAutoSyncRunning {
            return .running
        }
        if hold != nil {
            return .recoveryHold
        }
        if hasDeniedPermission(input.permissions) {
            return .permissionRequired
        }
        if input.isIncrementalDue == false {
            return .nothingDue
        }
        return .manualOnly
    }

    private static func hasDeniedPermission(_ permissions: ChromePermissions) -> Bool {
        permissions.isMusicAppAvailable == false
            || permissions.areScriptsInstalled == false
            || permissions.isMusicPermissionGranted == false
    }

    private static func makeCommands(input: ChromeInput, hold: ChromeRecoveryHold?) -> [ChromeCommandDescriptor] {
        var commands: [ChromeCommandDescriptor] = []
        // Recovery outranks new work as the primary call to action (ADR 0006).
        if hold != nil {
            commands.append(ChromeCommandDescriptor(
                id: "chrome.resume-recovery",
                title: "Resume recovery",
                isEnabled: input.isRunServiceAvailable,
                disabledReason: input.isRunServiceAvailable ? nil : "Services are still starting.",
                commandKind: .resumeRecovery
            ))
        }
        commands.append(makeRunCommand(input: input, hold: hold))
        if input.hasReviewableFixPlan, hold == nil {
            commands.append(ChromeCommandDescriptor(
                id: "chrome.review-changes",
                title: "Review changes",
                isEnabled: true,
                commandKind: .reviewChanges
            ))
        }
        return commands
    }

    private static func makeRunCommand(input: ChromeInput, hold: ChromeRecoveryHold?) -> ChromeCommandDescriptor {
        // A write hold degrades the run command to the read-only library
        // check instead of hiding or disabling it (ADR 0006).
        let variant: ActivityCommandVariant = hold == nil ? .standard : .libraryCheck
        let title = hold == nil ? "Run now" : "Check library"
        guard input.isRunServiceAvailable else {
            return ChromeCommandDescriptor(
                id: "chrome.run-manually",
                title: title,
                isEnabled: false,
                disabledReason: "Services are still starting.",
                commandKind: .runManually,
                variant: variant
            )
        }
        if let lifecycle = input.lifecycle, lifecycle.isActive, !lifecycle.canQueueManual {
            return ChromeCommandDescriptor(
                id: "chrome.run-manually",
                title: title,
                isEnabled: false,
                disabledReason: "A run is already in progress.",
                commandKind: .runManually,
                variant: variant
            )
        }
        return ChromeCommandDescriptor(
            id: "chrome.run-manually",
            title: title,
            isEnabled: true,
            commandKind: .runManually,
            variant: variant
        )
    }

    private static func makeIssues(input: ChromeInput) -> [OperationalIssue] {
        var issues: [OperationalIssue] = []
        if input.settingsLoadFailed {
            issues.append(OperationalIssue(
                id: "chrome.settings-load",
                category: .configurationRequired,
                summary: "Settings could not be loaded; defaults are in effect.",
                nextAction: "Review and save Settings to repair the stored configuration."
            ))
        }
        if let saveError = input.settingsSaveErrorMessage {
            issues.append(OperationalIssue(
                id: "chrome.settings-save",
                category: .temporaryUnavailable,
                summary: "Settings changes are not being saved.",
                technicalDetail: saveError,
                nextAction: "Check disk access for the configuration folder and retry."
            ))
        }
        if input.permissions.isMusicAppAvailable == false {
            issues.append(OperationalIssue(
                id: "chrome.music-unavailable",
                category: .musicUnavailable,
                summary: "Music.app is not available.",
                nextAction: "Open Music and try again."
            ))
        }
        if input.permissions.areScriptsInstalled == false {
            issues.append(OperationalIssue(
                id: "chrome.scripts-unavailable",
                category: .applicationScriptsUnavailable,
                summary: "Writer scripts are not installed.",
                nextAction: "Reinstall the Music scripts from onboarding."
            ))
        }
        if input.permissions.isMusicPermissionGranted == false {
            issues.append(OperationalIssue(
                id: "chrome.music-permission",
                category: .musicPermissionRequired,
                summary: "Music library access is not granted.",
                nextAction: "Allow Music access in System Settings › Privacy."
            ))
        }
        return issues
    }
}
