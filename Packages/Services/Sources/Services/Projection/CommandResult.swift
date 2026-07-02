import Foundation

public enum UserIntentCommandKind: String, Equatable, Sendable {
    case reviewChanges
    case runManually
}

public struct UserIntentCommand: Equatable, Sendable {
    public let id: UUID
    public let kind: UserIntentCommandKind

    private init(id: UUID, kind: UserIntentCommandKind) {
        self.id = id
        self.kind = kind
    }

    public static func reviewChanges(id: UUID = UUID()) -> Self {
        Self(id: id, kind: .reviewChanges)
    }

    public static func runManually(id: UUID = UUID()) -> Self {
        Self(id: id, kind: .runManually)
    }
}

public enum CommandResultStatus: String, Equatable, Sendable {
    case accepted
    case queued
    case alreadyCovered
    case noOp
    case rejectedStale
    case rejectedInvalid
    case requiresAttention
    case blockedByRecovery
    case blockedByPermission
    case temporaryUnavailable
    case navigated
}

public enum CommandSettingsSection: String, Equatable, Sendable {
    case general
    case apiAndCache
    case advanced
    case appearance
}

public enum CommandNavigationTarget: Equatable, Sendable {
    case activity
    case fixPlan(id: String)
    case report(id: String)
    case settings(section: CommandSettingsSection?)
}

public enum OperationalIssueCategory: String, Equatable, Sendable {
    case permissionRequired
    case configurationRequired
    case recoveryRequired
    case temporaryUnavailable
    case safetyBlocked
    case staleAction
    case internalFailure
    case musicPermissionRequired
    case musicUnavailable
    case automationPermissionRequired
    case applicationScriptsUnavailable
    case appleScriptWriteUnavailable
    case musicKitUnavailable
}

public struct OperationalIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: OperationalIssueCategory
    public let summary: String
    public let technicalDetail: String?

    public init(
        id: String,
        category: OperationalIssueCategory,
        summary: String,
        technicalDetail: String? = nil
    ) {
        self.id = id
        self.category = category
        self.summary = summary
        self.technicalDetail = technicalDetail
    }
}

public struct UserCommandResult: Equatable, Sendable {
    public let status: CommandResultStatus
    public let message: String
    public let navigationTarget: CommandNavigationTarget?
    public let issue: OperationalIssue?
    public let refreshedActivityProjection: ActivityProjection?

    private init(
        status: CommandResultStatus,
        message: String,
        navigationTarget: CommandNavigationTarget? = nil,
        issue: OperationalIssue? = nil,
        refreshedActivityProjection: ActivityProjection? = nil
    ) {
        self.status = status
        self.message = message
        self.navigationTarget = navigationTarget
        self.issue = issue
        self.refreshedActivityProjection = refreshedActivityProjection
    }

    public static func accepted(message: String, refreshedActivityProjection: ActivityProjection) -> Self {
        Self(status: .accepted, message: message, refreshedActivityProjection: refreshedActivityProjection)
    }

    public static func queued(message: String, refreshedActivityProjection: ActivityProjection) -> Self {
        Self(status: .queued, message: message, refreshedActivityProjection: refreshedActivityProjection)
    }

    public static func alreadyCovered(message: String, refreshedActivityProjection: ActivityProjection) -> Self {
        Self(status: .alreadyCovered, message: message, refreshedActivityProjection: refreshedActivityProjection)
    }

    public static func noOp(message: String, refreshedActivityProjection: ActivityProjection) -> Self {
        Self(status: .noOp, message: message, refreshedActivityProjection: refreshedActivityProjection)
    }

    public static func rejectedStale(message: String, refreshedActivityProjection: ActivityProjection) -> Self {
        Self(status: .rejectedStale, message: message, refreshedActivityProjection: refreshedActivityProjection)
    }

    public static func rejectedInvalid(
        message: String,
        issue: OperationalIssue,
        refreshedActivityProjection: ActivityProjection
    ) -> Self {
        Self(
            status: .rejectedInvalid,
            message: message,
            issue: issue,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }

    public static func requiresAttention(
        message: String,
        issue: OperationalIssue,
        refreshedActivityProjection: ActivityProjection
    ) -> Self {
        Self(
            status: .requiresAttention,
            message: message,
            issue: issue,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }

    public static func blockedByRecovery(
        message: String,
        issue: OperationalIssue,
        refreshedActivityProjection: ActivityProjection
    ) -> Self {
        Self(
            status: .blockedByRecovery,
            message: message,
            issue: issue,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }

    public static func blockedByPermission(
        message: String,
        issue: OperationalIssue,
        refreshedActivityProjection: ActivityProjection
    ) -> Self {
        Self(
            status: .blockedByPermission,
            message: message,
            issue: issue,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }

    public static func temporaryUnavailable(
        message: String,
        issue: OperationalIssue,
        refreshedActivityProjection: ActivityProjection
    ) -> Self {
        Self(
            status: .temporaryUnavailable,
            message: message,
            issue: issue,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }

    public static func navigated(
        message: String,
        navigationTarget: CommandNavigationTarget,
        refreshedActivityProjection: ActivityProjection? = nil
    ) -> Self {
        Self(
            status: .navigated,
            message: message,
            navigationTarget: navigationTarget,
            refreshedActivityProjection: refreshedActivityProjection
        )
    }
}
