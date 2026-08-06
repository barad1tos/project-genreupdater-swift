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
