import Core
import Foundation

public enum RunProcessingMode: String, Codable, Equatable, Sendable {
    case preview
    case autoFix
}

public enum WriteAuthority: String, Codable, Equatable, Sendable {
    case readOnly
    case reviewedPlan
    case automaticPlan

    public var canWritePlan: Bool {
        self == .reviewedPlan || self == .automaticPlan
    }
}

/// Immutable runtime choices captured when an orchestrated run starts.
public struct RunConfig: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let mode: RunProcessingMode
    public let writeAuthority: WriteAuthority
    public let automation: AutomationStrategy
    public let scopeID: UUID
    public let settings: FixPlanConfig
    public let hadRecoveryHold: Bool

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        mode: RunProcessingMode? = nil,
        writeAuthority: WriteAuthority,
        automation: AutomationStrategy,
        scopeID: UUID,
        settings: FixPlanConfig,
        hadRecoveryHold: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.mode = mode ?? Self.processingMode(from: settings)
        self.writeAuthority = writeAuthority
        self.automation = automation
        self.scopeID = scopeID
        self.settings = settings
        self.hadRecoveryHold = hadRecoveryHold
    }

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, mode, writeAuthority, automation, scopeID, settings, hadRecoveryHold
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        writeAuthority = try container.decode(WriteAuthority.self, forKey: .writeAuthority)
        automation = try container.decode(AutomationStrategy.self, forKey: .automation)
        scopeID = try container.decode(UUID.self, forKey: .scopeID)
        settings = try container.decode(FixPlanConfig.self, forKey: .settings)
        hadRecoveryHold = try container.decode(Bool.self, forKey: .hadRecoveryHold)
        mode = try container.decodeIfPresent(RunProcessingMode.self, forKey: .mode)
            ?? Self.processingMode(from: settings)
    }

    private static func processingMode(from settings: FixPlanConfig) -> RunProcessingMode {
        settings.appConfiguration.runtime.dryRun ? .preview : .autoFix
    }

    /// Compares canonical encoded values after applying configuration codec migrations.
    public static func == (left: Self, right: Self) -> Bool {
        guard let leftData = canonicalData(for: left),
              let rightData = canonicalData(for: right)
        else {
            return left.id == right.id
                && left.capturedAt == right.capturedAt
                && left.mode == right.mode
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
