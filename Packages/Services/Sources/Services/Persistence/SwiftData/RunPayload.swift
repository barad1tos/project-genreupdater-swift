import Foundation

public enum RunRecordPersistenceError: LocalizedError {
    case corruptedField(name: String, runID: UUID)
    case invalidField(name: String, runID: UUID)
    case malformedPayloadVersion(runID: UUID)
    case unsupportedPayloadVersion(version: Int, runID: UUID)

    public var errorDescription: String? {
        switch self {
        case let .corruptedField(name, runID):
            "Failed to decode run record \(runID.uuidString): corrupted field \(name)"
        case let .invalidField(name, runID):
            "Cannot persist run record \(runID.uuidString): invalid field \(name)"
        case let .malformedPayloadVersion(runID):
            "Cannot decode run record \(runID.uuidString): malformed payload version"
        case let .unsupportedPayloadVersion(version, runID):
            "Cannot decode run record \(runID.uuidString): unsupported payload version \(version)"
        }
    }
}

struct RunRecordPayload: Codable {
    static let legacyVersion = 1
    static let configurationVersion = 2
    static let currentVersion = 2

    // Stored in the legacy transitionsData column to avoid a SwiftData schema migration.
    // Version remains an integer across future schemas; malformed values are eligible for explicit corrupted closure.
    let version: Int
    let transitions: [RunLifecycleTransition]
    let configuration: RunConfig?
    let writeTarget: FixPlanWriteTarget?
    let recoveryID: UUID?
    let writeSummary: RunWriteSummary?

    init(record: RunRecord) {
        version = Self.version(for: record.configuration)
        transitions = record.transitions
        configuration = record.configuration
        writeTarget = record.writeTarget
        recoveryID = record.recoveryID
        writeSummary = record.writeSummary
    }

    init(
        version: Int,
        transitions: [RunLifecycleTransition],
        configuration: RunConfig?,
        writeTarget: FixPlanWriteTarget?,
        recoveryID: UUID?,
        writeSummary: RunWriteSummary?
    ) {
        self.version = version
        self.transitions = transitions
        self.configuration = configuration
        self.writeTarget = writeTarget
        self.recoveryID = recoveryID
        self.writeSummary = writeSummary
    }

    static func version(for configuration: RunConfig?) -> Int {
        configuration == nil ? legacyVersion : currentVersion
    }
}

struct RunPayloadVersion: Decodable {
    let version: Int
}

struct RecoveryPayload: Decodable {
    let version: Int?
    let transitions: [RunLifecycleTransition]?
    let configuration: RunConfig?
    let writeTarget: FixPlanWriteTarget?
    let recoveryID: UUID?
    let writeSummary: RunWriteSummary?
    let isWriteRecoveryRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case version, transitions, configuration, writeTarget, recoveryID, writeSummary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versionField = Self.decode(Int.self, forKey: .version, from: container)
        let transitionsField = Self.decode([RunLifecycleTransition].self, forKey: .transitions, from: container)
        let configurationField = Self.decode(RunConfig.self, forKey: .configuration, from: container)
        let writeTargetField = Self.decode(FixPlanWriteTarget.self, forKey: .writeTarget, from: container)
        let recoveryIDField = Self.decode(UUID.self, forKey: .recoveryID, from: container)
        let writeSummaryField = Self.decode(RunWriteSummary.self, forKey: .writeSummary, from: container)

        let decodedVersion = versionField.value
        let decodedConfiguration = configurationField.value
        version = decodedVersion
        transitions = transitionsField.value
        configuration = decodedConfiguration
        writeTarget = writeTargetField.value
        recoveryID = recoveryIDField.value
        writeSummary = writeSummaryField.value

        let hasMalformedField = versionField.isMalformed
            || transitionsField.isMalformed
            || configurationField.isMalformed
            || writeTargetField.isMalformed
            || recoveryIDField.isMalformed
            || writeSummaryField.isMalformed
        let hasInvalidVersion = decodedVersion.map {
            $0 < RunRecordPayload.legacyVersion || $0 > RunRecordPayload.currentVersion
        } ?? true
        let isMissingConfiguration = decodedVersion.map {
            $0 >= RunRecordPayload.configurationVersion && decodedConfiguration == nil
        } ?? false
        isWriteRecoveryRequired = hasMalformedField
            || hasInvalidVersion
            || transitions == nil
            || isMissingConfiguration
    }

    private static func decode<Value: Decodable>(
        _: Value.Type,
        forKey key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> (value: Value?, isMalformed: Bool) {
        guard container.contains(key) else { return (nil, false) }
        do {
            return try (container.decodeIfPresent(Value.self, forKey: key), false)
        } catch {
            return (nil, true)
        }
    }
}
