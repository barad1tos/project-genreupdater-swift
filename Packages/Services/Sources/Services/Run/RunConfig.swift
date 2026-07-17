import Foundation

public enum RunProcessingMode: String, Codable, Equatable, Sendable {
    case preview
    case autoFix
}

public enum WriteAuthority: String, Codable, Equatable, Sendable {
    case readOnly
    case reviewedPlan
}

public enum AutomationStrategy: String, Codable, Equatable, Sendable {
    case manualOnly
    case libraryChange
    case scheduled
    case hybrid
}

/// Immutable runtime choices captured when an orchestrated run starts.
public struct RunConfig: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let writeAuthority: WriteAuthority
    public let automation: AutomationStrategy
    public let scopeID: UUID
    public let settings: FixPlanConfig
    public let hadRecoveryHold: Bool

    /// Processing policy captured from runtime settings, independent of request intent and write authority.
    public var mode: RunProcessingMode {
        settings.appConfiguration.runtime.dryRun ? .preview : .autoFix
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        writeAuthority: WriteAuthority,
        automation: AutomationStrategy,
        scopeID: UUID,
        settings: FixPlanConfig,
        hadRecoveryHold: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.writeAuthority = writeAuthority
        self.automation = automation
        self.scopeID = scopeID
        self.settings = settings
        self.hadRecoveryHold = hadRecoveryHold
    }

    /// Compares canonical encoded values after applying configuration codec migrations.
    public static func == (left: Self, right: Self) -> Bool {
        guard let leftData = canonicalData(for: left),
              let rightData = canonicalData(for: right)
        else {
            return left.id == right.id
                && left.capturedAt == right.capturedAt
                && left.writeAuthority == right.writeAuthority
                && left.automation == right.automation
                && left.scopeID == right.scopeID
                && left.settings == right.settings
                && left.hadRecoveryHold == right.hadRecoveryHold
        }
        return leftData == rightData
    }

    /// Applies current codec migrations before comparing canonical bytes.
    private static func canonicalData(for configuration: Self) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        guard let data = try? encoder.encode(configuration),
              let normalized = try? decoder.decode(Self.self, from: data)
        else { return nil }
        return try? encoder.encode(normalized)
    }
}
