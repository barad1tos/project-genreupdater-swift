import Foundation
import OSLog

enum RunPayloadCodec {
    private static let log = Logger(subsystem: "com.genreupdater", category: "RunPayloadCodec")

    static func decode(from persisted: PersistedRunRecord) throws -> RunRecordPayload {
        let decoder = JSONDecoder()
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: persisted.transitionsData)
        } catch {
            return try decodeLegacy(from: persisted)
        }
        if json is [Any] {
            return try decodeLegacy(from: persisted)
        }
        guard json is [String: Any] else {
            throw RunRecordPersistenceError.corruptedField(name: "payload", runID: persisted.runID)
        }

        let payloadVersion: Int
        do {
            payloadVersion = try decoder.decode(
                RunPayloadVersion.self,
                from: persisted.transitionsData
            ).version
        } catch {
            throw RunRecordPersistenceError.malformedPayloadVersion(runID: persisted.runID)
        }

        guard payloadVersion >= RunRecordPayload.legacyVersion else {
            throw RunRecordPersistenceError.malformedPayloadVersion(runID: persisted.runID)
        }
        guard payloadVersion <= RunRecordPayload.currentVersion else {
            throw RunRecordPersistenceError.unsupportedPayloadVersion(
                version: payloadVersion,
                runID: persisted.runID
            )
        }
        do {
            return try decoder.decode(RunRecordPayload.self, from: persisted.transitionsData)
        } catch {
            throw RunRecordPersistenceError.corruptedField(
                name: corruptedFieldName(from: error),
                runID: persisted.runID
            )
        }
    }

    static func decodeForRecovery(
        from persisted: PersistedRunRecord
    ) throws -> (payload: RunRecordPayload?, fallback: RecoveryPayload?) {
        do {
            return try (decode(from: persisted), nil)
        } catch let error as RunRecordPersistenceError {
            if case .unsupportedPayloadVersion = error {
                throw error
            }
            return (
                nil,
                try? JSONDecoder().decode(RecoveryPayload.self, from: persisted.transitionsData)
            )
        }
    }

    private static func corruptedFieldName(from error: any Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, _):
            key.stringValue
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context),
             let DecodingError.dataCorrupted(context):
            context.codingPath.last?.stringValue ?? "payload"
        default:
            "payload"
        }
    }

    private static func decodeLegacy(from persisted: PersistedRunRecord) throws -> RunRecordPayload {
        do {
            let transitions = try JSONDecoder().decode([RunLifecycleTransition].self, from: persisted.transitionsData)
            return RunRecordPayload(
                version: RunRecordPayload.legacyVersion,
                transitions: transitions,
                configuration: nil,
                writeTarget: nil,
                recoveryID: nil,
                writeSummary: nil
            )
        } catch {
            log.error("""
            Corrupted transitions blob in run record \(persisted.runID.uuidString, privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
            throw RunRecordPersistenceError.corruptedField(name: "transitions", runID: persisted.runID)
        }
    }
}
