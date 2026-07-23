import Foundation
import SwiftData

extension RunRecordDataStore {
    public func recoveryRecords() async throws -> RunReportPage {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try makePage(from: modelContext.fetch(descriptor)) {
            $0.finishedAt == nil && RunIntent(rawValue: $0.intentRaw) == .writeFixes
        }
    }

    public func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        let after = query.startedAfter ?? Date.distantPast
        let before = query.startedBefore ?? Date.distantFuture
        let stateFilter = Set((query.states ?? []).map(\.rawValue))
        let filtersState = !stateFilter.isEmpty
        let triggerFilter = query.trigger?.rawValue ?? ""
        let filtersTrigger = !triggerFilter.isEmpty

        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { row in
                row.startedAt >= after && row.startedAt <= before
                    && (!filtersState || stateFilter.contains(row.stateRaw))
                    && (!filtersTrigger || row.triggerRaw == triggerFilter)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit = query.limit, limit > 0 {
            descriptor.fetchLimit = limit
        }

        return try makePage(from: modelContext.fetch(descriptor))
    }

    func makePage(
        from rows: [PersistedRunRecord],
        including shouldInclude: (PersistedRunRecord) -> Bool = { _ in true }
    ) throws -> RunReportPage {
        var records: [RunRecord] = []
        var corruptedRunIDs: [RunID] = []
        var recoveryRunIDs: [RunID] = []
        var closableRunIDs: [RunID] = []
        var attentionRunIDs: [RunID] = []
        var unsupportedRunIDs: [RunID] = []
        var skippedCorruptedCount = 0
        for row in rows {
            let isIncluded = shouldInclude(row)
            do {
                let record = try makeRecord(from: row)
                if isIncluded {
                    records.append(record)
                }
            } catch let error as RunRecordPersistenceError {
                skippedCorruptedCount += 1
                let runID = RunID(rawValue: row.runID)
                corruptedRunIDs.append(runID)
                switch corruptionRoute(for: row) {
                case .writeRecovery:
                    recoveryRunIDs.append(runID)
                case .readOnlyClosure:
                    closableRunIDs.append(runID)
                case .attention:
                    attentionRunIDs.append(runID)
                case .diagnostic:
                    break
                case .unsupported:
                    unsupportedRunIDs.append(runID)
                }
                log.error("""
                Skipping corrupted run record \(row.runID.uuidString, privacy: .public) \
                in report query: \(error.localizedDescription, privacy: .public)
                """)
            }
        }

        return RunReportPage(
            records: records,
            skippedCorruptedCount: skippedCorruptedCount,
            corruptedRunIDs: corruptedRunIDs,
            recoveryRunIDs: recoveryRunIDs,
            closableRunIDs: closableRunIDs,
            attentionRunIDs: attentionRunIDs,
            unsupportedRunIDs: unsupportedRunIDs
        )
    }
}
