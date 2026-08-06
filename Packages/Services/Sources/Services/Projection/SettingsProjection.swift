import Core
import Foundation

/// The one read surface the settings UI needs (ADR 0022): the current
/// configuration, the global settings revision commands CAS against, and
/// the last save failure. Published only by the settings command path.
public struct SettingsProjection: Sendable {
    public let revision: ProjectionRevision
    /// The CAS anchor (`AppConfiguration.revision`) at publication time.
    public let settingsRevision: UInt64
    public let configuration: AppConfiguration
    /// Human-readable persistence failure; nil when the last save landed.
    public let saveErrorMessage: String?

    public init(
        revision: ProjectionRevision,
        settingsRevision: UInt64,
        configuration: AppConfiguration,
        saveErrorMessage: String?
    ) {
        self.revision = revision
        self.settingsRevision = settingsRevision
        self.configuration = configuration
        self.saveErrorMessage = saveErrorMessage
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            settingsRevision: 0,
            configuration: AppConfiguration(),
            saveErrorMessage: nil
        )
    }

    func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            settingsRevision: settingsRevision,
            configuration: configuration,
            saveErrorMessage: saveErrorMessage
        )
    }
}

/// CAS target every settings mutation carries (ADR 0011): the settings
/// revision the caller last saw plus the projection revision it rendered.
public struct SettingsCommandTarget: Equatable, Sendable {
    public let expectedSettingsRevision: UInt64
    public let projectionRevision: ProjectionRevision

    public init(expectedSettingsRevision: UInt64, projectionRevision: ProjectionRevision) {
        self.expectedSettingsRevision = expectedSettingsRevision
        self.projectionRevision = projectionRevision
    }
}

/// Typed result of a settings command (ADR 0014): the refreshed settings
/// projection always rides along; a fingerprint-relevant accept also
/// carries the refreshed fix-plan projection (ADR 0022 staleness push).
public struct SettingsCommandResult: Sendable {
    public let status: CommandResultStatus
    public let message: String
    public let refreshedSettings: SettingsProjection
    public let refreshedFixPlan: FixPlanProjection?

    private init(
        status: CommandResultStatus,
        message: String,
        refreshedSettings: SettingsProjection,
        refreshedFixPlan: FixPlanProjection? = nil
    ) {
        self.status = status
        self.message = message
        self.refreshedSettings = refreshedSettings
        self.refreshedFixPlan = refreshedFixPlan
    }

    public static func accepted(
        message: String,
        refreshedSettings: SettingsProjection,
        refreshedFixPlan: FixPlanProjection? = nil
    ) -> Self {
        Self(
            status: .accepted,
            message: message,
            refreshedSettings: refreshedSettings,
            refreshedFixPlan: refreshedFixPlan
        )
    }

    public static func rejectedStale(message: String, refreshedSettings: SettingsProjection) -> Self {
        Self(status: .rejectedStale, message: message, refreshedSettings: refreshedSettings)
    }

    public static func temporaryUnavailable(message: String, refreshedSettings: SettingsProjection) -> Self {
        Self(status: .temporaryUnavailable, message: message, refreshedSettings: refreshedSettings)
    }
}

extension SettingsProjection: Equatable {
    /// `AppConfiguration` carries no synthesized equality; canonical
    /// sorted-keys bytes stand in (the RunConfig precedent), falling back
    /// to the revision fields when encoding fails.
    public static func == (left: Self, right: Self) -> Bool {
        guard left.revision == right.revision,
              left.settingsRevision == right.settingsRevision,
              left.saveErrorMessage == right.saveErrorMessage
        else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let leftData = try? encoder.encode(left.configuration),
              let rightData = try? encoder.encode(right.configuration)
        else { return false }
        return leftData == rightData
    }
}
