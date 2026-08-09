import Core
import Foundation

/// Facts about the run service and its current lifecycle.
public struct ChromeRunFacts: Sendable {
    public let lifecycle: RunLifecycleSnapshot?
    public let isRunServiceAvailable: Bool

    public init(lifecycle: RunLifecycleSnapshot?, isRunServiceAvailable: Bool) {
        self.lifecycle = lifecycle
        self.isRunServiceAvailable = isRunServiceAvailable
    }
}

/// The unresolved write-recovery fact, sourced from the run store — never
/// from a UI-refresh-cadence projection.
public struct ChromeRecoveryFacts: Sendable {
    public let hasUnresolvedWriteRecovery: Bool
    public let recoveryRunID: RunID?

    public init(hasUnresolvedWriteRecovery: Bool, recoveryRunID: RunID?) {
        self.hasUnresolvedWriteRecovery = hasUnresolvedWriteRecovery
        self.recoveryRunID = recoveryRunID
    }
}

/// Settings-derived facts: mode plus persistence health.
public struct ChromeSettingsFacts: Sendable {
    public let isPreviewMode: Bool
    public let saveErrorMessage: String?
    public let hasLoadFailed: Bool

    public init(isPreviewMode: Bool, saveErrorMessage: String?, hasLoadFailed: Bool) {
        self.isPreviewMode = isPreviewMode
        self.saveErrorMessage = saveErrorMessage
        self.hasLoadFailed = hasLoadFailed
    }
}

/// Automation cadence facts (ADR 0003): the persisted strategy plus
/// what the runtime actually armed.
public struct ChromeAutomationFacts: Sendable {
    public let strategy: AutomationStrategy
    public let isScheduleArmed: Bool
    public let isIncrementalDue: Bool?

    public init(strategy: AutomationStrategy, isScheduleArmed: Bool, isIncrementalDue: Bool?) {
        self.strategy = strategy
        self.isScheduleArmed = isScheduleArmed
        self.isIncrementalDue = isIncrementalDue
    }
}

/// Library facts: the whole-Music.app count and the active run's scope
/// snapshot (ADR 0020 — never live settings).
public struct ChromeLibraryFacts: Sendable {
    public let physicalTrackCount: Int?
    public let scope: ProcessingScopeSnapshot?

    public init(physicalTrackCount: Int?, scope: ProcessingScopeSnapshot?) {
        self.physicalTrackCount = physicalTrackCount
        self.scope = scope
    }
}

/// Raw facts the app layer snapshots for chrome assembly. Every field is a
/// probed truth or an immutable snapshot — the builder never reads live
/// mutable state (analysis D7/D9).
public struct ChromeInput: Sendable {
    public let run: ChromeRunFacts
    public let recovery: ChromeRecoveryFacts
    public let settings: ChromeSettingsFacts
    public let automation: ChromeAutomationFacts
    public let library: ChromeLibraryFacts
    public let permissions: ChromePermissions

    public init(
        run: ChromeRunFacts,
        recovery: ChromeRecoveryFacts,
        settings: ChromeSettingsFacts,
        automation: ChromeAutomationFacts,
        library: ChromeLibraryFacts,
        permissions: ChromePermissions
    ) {
        self.run = run
        self.recovery = recovery
        self.settings = settings
        self.automation = automation
        self.library = library
        self.permissions = permissions
    }
}

/// Assembles the shared shell truth (ADR 0012) from probed facts. Pure and
/// synchronous so every rule is a pinned truth table.
public enum ChromeBuilder {
    public static func makeProjection(input: ChromeInput) -> ChromeProjection {
        let hold = makeRecoveryHold(input: input)
        return ChromeProjection(
            revision: .initial,
            identity: ChromeShellIdentity(title: "Genre Updater", subtitle: nil),
            syncStatus: makeSyncStatus(input: input, hold: hold),
            library: ChromeLibrarySummary(
                physicalTrackCount: input.library.physicalTrackCount,
                effectiveScope: makeScope(input: input)
            ),
            safety: ChromeSafetyState(
                isPreviewMode: input.settings.isPreviewMode,
                processingModeLabel: input.settings.isPreviewMode ? "Preview" : "Auto-fix",
                automationState: makeAutomationState(input: input, hold: hold),
                recoveryHold: hold,
                permissions: input.permissions
            ),
            commands: makeCommands(input: input, hold: hold),
            operationalIssues: makeIssues(input: input)
        )
    }

    private static func makeRecoveryHold(input: ChromeInput) -> ChromeRecoveryHold? {
        guard input.recovery.hasUnresolvedWriteRecovery else { return nil }
        return ChromeRecoveryHold(blocksWrites: true, runID: input.recovery.recoveryRunID)
    }

    private static func makeSyncStatus(input: ChromeInput, hold: ChromeRecoveryHold?) -> ChromeSyncStatus {
        let isRunActive = input.run.lifecycle?.isActive == true
        guard let state = input.run.lifecycle?.state else {
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
        guard let scope = input.library.scope else { return nil }
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
        if input.run.lifecycle?.isActive == true {
            return .running
        }
        if hold != nil {
            return .recoveryHold
        }
        if hasDeniedPermission(input.permissions) {
            return .permissionRequired
        }
        if input.automation.isScheduleArmed {
            // Armed is not running: the source waits for its next tick.
            return .scheduled
        }
        if input.automation.isIncrementalDue == false {
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
                isEnabled: input.run.isRunServiceAvailable,
                disabledReason: input.run.isRunServiceAvailable ? nil : "Services are still starting.",
                commandKind: .resumeRecovery
            ))
        }
        commands.append(makeRunCommand(input: input, hold: hold))
        return commands
    }

    /// The availability predicate lives here, on probed facts (D9): a
    /// proven-unavailable Music.app refuses the run (the Python P30
    /// refusal analog), never just "the service object exists".
    private static func makeRunCommand(input: ChromeInput, hold: ChromeRecoveryHold?) -> ChromeCommandDescriptor {
        // A write hold degrades the run command to the read-only library
        // check instead of hiding or disabling it (ADR 0006).
        let variant: ActivityCommandVariant = hold == nil ? .standard : .libraryCheck
        let title = hold == nil ? "Run now" : "Check library"
        let disabledReason: String? = if !input.run.isRunServiceAvailable {
            "Services are still starting."
        } else if input.permissions.isMusicAppAvailable == false {
            "Music.app is not available."
        } else if let lifecycle = input.run.lifecycle, lifecycle.isActive, !lifecycle.canQueueManual {
            "A run is already in progress."
        } else {
            nil
        }
        return ChromeCommandDescriptor(
            id: "chrome.run-manually",
            title: title,
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason,
            commandKind: .runManually,
            variant: variant
        )
    }

    private static func makeIssues(input: ChromeInput) -> [OperationalIssue] {
        var issues: [OperationalIssue] = []
        if input.settings.hasLoadFailed {
            issues.append(OperationalIssue(
                id: "chrome.settings-load",
                category: .configurationRequired,
                summary: "Settings could not be loaded; defaults are in effect.",
                nextAction: "Review and save Settings to repair the stored configuration."
            ))
        }
        if let saveError = input.settings.saveErrorMessage {
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
