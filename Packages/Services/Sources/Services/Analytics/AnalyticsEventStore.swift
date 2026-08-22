import Core
import Foundation

struct StoredAnalyticsEvent: Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let operationValue: String
    let startedAt: Date
    let durationSeconds: Double
    let outcome: AnalyticsOutcome
}

struct AnalyticsRetentionPolicy: Sendable {
    let maxEvents: Int
    let cutoff: Date
}

protocol AnalyticsEventStore: Sendable {
    func append(_ event: StoredAnalyticsEvent, retention: AnalyticsRetentionPolicy) async throws
    func events(since cutoff: Date?, sessionID: UUID?) async throws -> [StoredAnalyticsEvent]
    func migrateLegacyAnalytics(retention: AnalyticsRetentionPolicy) async throws
}

enum AnalyticsStoreError: Error, Equatable {
    case invalidDuration
    case invalidIdentifier(String)
    case invalidOutcome(String)
}

enum AnalyticsLegacy {
    static let eventsCacheKey = "analytics:events"
    static let sessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
}

struct LegacyAnalyticsEvent: Decodable {
    let eventType: String
    let timestamp: Date
    let durationSeconds: Double
    let metadata: [String: String]

    func storedEvent(index: Int, sessionID: UUID) throws -> StoredAnalyticsEvent {
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            throw AnalyticsStoreError.invalidDuration
        }

        let suffix = ".error"
        let hasErrorSuffix = eventType.hasSuffix(suffix)
        let operation = hasErrorSuffix ? String(eventType.dropLast(suffix.count)) : eventType
        let outcome = metadata["outcome"].flatMap(AnalyticsOutcome.init(rawValue:))
            ?? (hasErrorSuffix ? .failed : .succeeded)
        let identifier = String(format: "00000000-0000-0001-0000-%012d", index)
        guard let id = UUID(uuidString: identifier) else {
            throw AnalyticsStoreError.invalidIdentifier(identifier)
        }
        return StoredAnalyticsEvent(
            id: id,
            sessionID: sessionID,
            operationValue: operation,
            startedAt: timestamp,
            durationSeconds: durationSeconds,
            outcome: outcome
        )
    }
}
