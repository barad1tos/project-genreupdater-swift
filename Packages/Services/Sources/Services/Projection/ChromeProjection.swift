import Core
import Foundation

/// Severity of the shell status affordance (ADR 0016 mapping target).
public enum ChromeStatusSeverity: String, Equatable, Sendable {
    case nominal
    case attention
    case blocked
}

/// The lifecycle-derived sync line every shell zone renders identically.
public struct ChromeSyncStatus: Equatable, Sendable {
    public let text: String
    public let severity: ChromeStatusSeverity
    public let isRunActive: Bool

    public init(text: String, severity: ChromeStatusSeverity, isRunActive: Bool) {
        self.text = text
        self.severity = severity
        self.isRunActive = isRunActive
    }
}

/// The effective processing scope as shell truth — always sourced from an
/// immutable scope snapshot, never from live settings (ADR 0020).
public struct ChromeScopeSummary: Equatable, Sendable {
    public let sourceLabel: String
    public let detailLabel: String?
    public let isNarrowedFromPhysical: Bool

    public init(sourceLabel: String, detailLabel: String?, isNarrowedFromPhysical: Bool) {
        self.sourceLabel = sourceLabel
        self.detailLabel = detailLabel
        self.isNarrowedFromPhysical = isNarrowedFromPhysical
    }
}

/// An unresolved recovery hold as compact shell truth (ADR 0006): visible
/// without an open window, orthogonal to the processing mode.
public struct ChromeRecoveryHold: Equatable, Sendable {
    public let blocksWrites: Bool
    public let runID: RunID?

    public init(blocksWrites: Bool, runID: RunID?) {
        self.blocksWrites = blocksWrites
        self.runID = runID
    }
}

/// Compact automation state for chrome. Watch/schedule/hybrid cases arrive
/// with slice 12; adding cases is additive for internal consumers.
public enum ChromeAutomationState: String, Equatable, Sendable {
    case running
    case manualOnly
    case nothingDue
    case recoveryHold
    case permissionRequired
}

/// Probed availability facts. A nil field means "not probed" — chrome must
/// never assert an OK it cannot prove (analysis D7).
public struct ChromePermissions: Equatable, Sendable {
    public let isMusicAppAvailable: Bool?
    public let areScriptsInstalled: Bool?
    public let isMusicPermissionGranted: Bool?
    public let isDiscogsAccessAvailable: Bool?

    public init(
        isMusicAppAvailable: Bool? = nil,
        areScriptsInstalled: Bool? = nil,
        isMusicPermissionGranted: Bool? = nil,
        isDiscogsAccessAvailable: Bool? = nil
    ) {
        self.isMusicAppAvailable = isMusicAppAvailable
        self.areScriptsInstalled = areScriptsInstalled
        self.isMusicPermissionGranted = isMusicPermissionGranted
        self.isDiscogsAccessAvailable = isDiscogsAccessAvailable
    }

    public static let unprobed = Self()
}

/// A shell command with its availability truth. A disabled command always
/// carries the reason; a write-held run command degrades to the read-only
/// `.libraryCheck` variant instead of disappearing (ADR 0006).
public struct ChromeCommandDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isEnabled: Bool
    public let disabledReason: String?
    public let commandKind: UserIntentCommandKind
    public let variant: ActivityCommandVariant

    public init(
        id: String,
        title: String,
        isEnabled: Bool,
        disabledReason: String? = nil,
        commandKind: UserIntentCommandKind,
        variant: ActivityCommandVariant = .standard
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.commandKind = commandKind
        self.variant = variant
    }
}

/// Shell identity, distinct from any screen's title (analysis P-checklist).
public struct ChromeShellIdentity: Equatable, Sendable {
    public let title: String
    public let subtitle: String?

    public init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// The physical-vs-effective scope pair (ADR 0020 / CONTEXT both-visible
/// rule): the physical count describes Music.app as a whole, the scope
/// describes what a run may touch.
public struct ChromeLibrarySummary: Equatable, Sendable {
    public let physicalTrackCount: Int?
    public let effectiveScope: ChromeScopeSummary?

    public init(physicalTrackCount: Int?, effectiveScope: ChromeScopeSummary?) {
        self.physicalTrackCount = physicalTrackCount
        self.effectiveScope = effectiveScope
    }
}

/// The safety facts chrome must keep orthogonal (ADR 0006): processing
/// mode, automation state, recovery hold, and probed permissions.
public struct ChromeSafetyState: Equatable, Sendable {
    public let processingModeLabel: String
    public let automationState: ChromeAutomationState
    public let recoveryHold: ChromeRecoveryHold?
    public let permissions: ChromePermissions

    public init(
        processingModeLabel: String,
        automationState: ChromeAutomationState,
        recoveryHold: ChromeRecoveryHold?,
        permissions: ChromePermissions
    ) {
        self.processingModeLabel = processingModeLabel
        self.automationState = automationState
        self.recoveryHold = recoveryHold
        self.permissions = permissions
    }
}

/// The one shell truth for the main window, status bar, and app commands
/// (ADR 0012): sync, scope, recovery hold, permission, and command state.
/// Other projections may carry derived display copies; this is the source.
public struct ChromeProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let identity: ChromeShellIdentity
    public let syncStatus: ChromeSyncStatus
    public let library: ChromeLibrarySummary
    public let safety: ChromeSafetyState
    public let commands: [ChromeCommandDescriptor]
    public let operationalIssues: [OperationalIssue]

    public init(
        revision: ProjectionRevision,
        identity: ChromeShellIdentity,
        syncStatus: ChromeSyncStatus,
        library: ChromeLibrarySummary,
        safety: ChromeSafetyState,
        commands: [ChromeCommandDescriptor],
        operationalIssues: [OperationalIssue]
    ) {
        self.revision = revision
        self.identity = identity
        self.syncStatus = syncStatus
        self.library = library
        self.safety = safety
        self.commands = commands
        self.operationalIssues = operationalIssues
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            identity: ChromeShellIdentity(title: "Genre Updater", subtitle: nil),
            syncStatus: ChromeSyncStatus(text: "Idle", severity: .nominal, isRunActive: false),
            library: ChromeLibrarySummary(physicalTrackCount: nil, effectiveScope: nil),
            safety: ChromeSafetyState(
                processingModeLabel: "Preview",
                automationState: .manualOnly,
                recoveryHold: nil,
                permissions: .unprobed
            ),
            commands: [],
            operationalIssues: []
        )
    }

    func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            identity: identity,
            syncStatus: syncStatus,
            library: library,
            safety: safety,
            commands: commands,
            operationalIssues: operationalIssues
        )
    }
}
