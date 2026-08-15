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
    static let workItemVersion = 3
    static let checkpointEvidenceVersion = 4
    static let currentVersion = checkpointEvidenceVersion

    // Stored in the legacy transitionsData column to avoid a SwiftData schema migration.
    // Version remains an integer across future schemas; malformed values are eligible for explicit corrupted closure.
    let version: Int
    let transitions: [RunLifecycleTransition]
    let workItems: [RunWorkItem]
    let configuration: RunConfig?
    let writeTarget: FixPlanWriteTarget?
    let recoveryID: UUID?
    let continuesRunID: RunID?
    let writeSummary: RunWriteSummary?

    init(record: RunRecord, preservingVersion storedVersion: Int? = nil) {
        version = Self.recordVersion(
            for: record.configuration,
            preserving: storedVersion
        )
        transitions = record.transitions
        workItems = record.workItems
        configuration = record.configuration
        writeTarget = record.writeTarget
        recoveryID = record.recoveryID
        continuesRunID = record.continuesRunID
        writeSummary = record.writeSummary
    }

    /// Rebuilds a payload from parts; the schema version is derived from the
    /// configuration exactly as `init(record:)` does, so callers cannot desync
    /// version and content.
    init(
        transitions: [RunLifecycleTransition],
        workItems: [RunWorkItem],
        configuration: RunConfig?,
        writeTarget: FixPlanWriteTarget?,
        recoveryID: UUID?,
        continuesRunID: RunID?,
        writeSummary: RunWriteSummary?,
        preservingVersion storedVersion: Int? = nil
    ) {
        version = Self.recoveryVersion(
            for: configuration,
            preserving: storedVersion,
            workItems: workItems
        )
        self.transitions = transitions
        self.workItems = workItems
        self.configuration = configuration
        self.writeTarget = writeTarget
        self.recoveryID = recoveryID
        self.continuesRunID = continuesRunID
        self.writeSummary = writeSummary
    }

    private static func recordVersion(
        for configuration: RunConfig?,
        preserving storedVersion: Int?
    ) -> Int {
        guard configuration != nil else { return legacyVersion }
        if let storedVersion,
           (configurationVersion ... currentVersion).contains(storedVersion) {
            return storedVersion
        }
        return currentVersion
    }

    private static func recoveryVersion(
        for configuration: RunConfig?,
        preserving storedVersion: Int?,
        workItems: [RunWorkItem]
    ) -> Int {
        guard configuration != nil else { return legacyVersion }
        if let storedVersion,
           (configurationVersion ... currentVersion).contains(storedVersion) {
            return storedVersion
        }
        return workItems.allSatisfy(\.isWriteEvidenceComplete) ? currentVersion : workItemVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, transitions, workItems, configuration, writeTarget, recoveryID, writeSummary
        case continuesRunID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        transitions = try container.decode([RunLifecycleTransition].self, forKey: .transitions)
        if version >= Self.checkpointEvidenceVersion {
            do {
                workItems = try container.decode(
                    [CurrentWorkItemPayload].self,
                    forKey: .workItems
                ).map(\.item)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .workItems,
                    in: container,
                    debugDescription: "Current work-item evidence is incomplete or malformed"
                )
            }
        } else if version >= Self.workItemVersion {
            workItems = try container.decode([RunWorkItem].self, forKey: .workItems)
        } else {
            workItems = []
        }
        configuration = try container.decodeIfPresent(RunConfig.self, forKey: .configuration)
        writeTarget = try container.decodeIfPresent(FixPlanWriteTarget.self, forKey: .writeTarget)
        recoveryID = try container.decodeIfPresent(UUID.self, forKey: .recoveryID)
        continuesRunID = try container.decodeIfPresent(RunID.self, forKey: .continuesRunID)
        writeSummary = try container.decodeIfPresent(RunWriteSummary.self, forKey: .writeSummary)
    }
}

struct RunPayloadVersion: Decodable {
    let version: Int
}

/// Per-field tolerant salvage decode for rows the strict payload rejects.
/// Its coding keys are a durable cross-version contract: forward-schema
/// salvage (continuation references, plan retention) reads THESE names, so
/// renaming a payload field silently breaks salvage for rows written by the
/// other version — keep old keys decodable when evolving the schema.
struct RecoveryPayload: Decodable {
    let version: Int?
    let transitions: [RunLifecycleTransition]?
    let workItems: [RunWorkItem]?
    let configuration: RunConfig?
    let writeTarget: FixPlanWriteTarget?
    let recoveryID: UUID?
    let continuesRunID: RunID?
    let writeSummary: RunWriteSummary?
    let hasMalformedItems: Bool
    let isWriteRecoveryRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case version, transitions, workItems, configuration, writeTarget, recoveryID, writeSummary
        case continuesRunID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let versionField = Self.decode(Int.self, forKey: .version, from: container)
        let transitionsField = Self.decode([RunLifecycleTransition].self, forKey: .transitions, from: container)
        let workItemsField = Self.decode([RunWorkItem].self, forKey: .workItems, from: container)
        let configurationField = Self.decode(RunConfig.self, forKey: .configuration, from: container)
        let writeTargetField = Self.decode(FixPlanWriteTarget.self, forKey: .writeTarget, from: container)
        let recoveryIDField = Self.decode(UUID.self, forKey: .recoveryID, from: container)
        let continuesRunIDField = Self.decode(RunID.self, forKey: .continuesRunID, from: container)
        let writeSummaryField = Self.decode(RunWriteSummary.self, forKey: .writeSummary, from: container)

        let decodedVersion = versionField.value
        let decodedConfiguration = configurationField.value
        let hasConfigurationField = container.contains(.configuration)
        let hasWorkItemsField = container.contains(.workItems)
        let supportsWorkItems = decodedVersion.map { $0 >= RunRecordPayload.workItemVersion } == true
        let hasUnknownSchema = decodedVersion.map { $0 < RunRecordPayload.legacyVersion } ?? true
        let hasUnknownItemAudit = hasUnknownSchema
            && (workItemsField.isMalformed
                || workItemsField.value?.isEmpty == false
                || (workItemsField.value == nil && (hasConfigurationField || hasWorkItemsField)))
        version = decodedVersion
        transitions = transitionsField.value
        workItems = supportsWorkItems || hasUnknownSchema ? workItemsField.value : []
        configuration = decodedConfiguration
        writeTarget = writeTargetField.value
        recoveryID = recoveryIDField.value
        continuesRunID = continuesRunIDField.value
        writeSummary = writeSummaryField.value

        hasMalformedItems = (supportsWorkItems && (workItemsField.value == nil || workItemsField.isMalformed))
            || hasUnknownItemAudit
        let hasMalformedField = versionField.isMalformed
            || transitionsField.isMalformed
            || hasMalformedItems
            || configurationField.isMalformed
            || writeTargetField.isMalformed
            || recoveryIDField.isMalformed
            || continuesRunIDField.isMalformed
            || writeSummaryField.isMalformed
        let hasInvalidVersion = decodedVersion.map {
            $0 < RunRecordPayload.legacyVersion || $0 > RunRecordPayload.currentVersion
        } ?? true
        let isMissingConfiguration = decodedVersion.map {
            $0 >= RunRecordPayload.configurationVersion && decodedConfiguration == nil
        } ?? false
        let isMissingWorkItems = supportsWorkItems && workItemsField.value == nil
        isWriteRecoveryRequired = hasMalformedField
            || hasInvalidVersion
            || transitions == nil
            || isMissingConfiguration
            || isMissingWorkItems
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
