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

    public func resolvedRecoveryRun(recoveryID: UUID) async throws -> RunID? {
        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { $0.recoveryIDRaw == recoveryID && $0.finishedAt != nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        if let row = try modelContext.fetch(descriptor).first {
            return RunID(rawValue: row.runID)
        }
        // Rows persisted before the recovery column existed carry nil there;
        // the payload scan keeps them resolvable and is removable once no
        // pre-column rows remain in the wild.
        let history = try await reports(matching: RunReportQuery())
        return history.records.first { $0.recoveryID == recoveryID && $0.finishedAt != nil }?.runID
    }

    public func reportItems(matching query: RunReportItemQuery) async throws -> RunReportItemPage {
        let after = query.startedAfter ?? Date.distantPast
        let before = query.startedBefore ?? Date.distantFuture
        let outcomeFilter = Set((query.outcomes ?? []).map {
            PersistedRunReportItem.stateRaw(for: .outcome($0))
        })
        let filtersOutcome = !outcomeFilter.isEmpty
        let changeTypeFilter = Set((query.changeTypes ?? []).map(\.rawValue))
        let filtersChangeType = !changeTypeFilter.isEmpty
        let filtersRun = query.runID != nil
        // Dead operand when filtersRun is false; a fresh UUID can never
        // collide into accidental matches.
        let runFilter = query.runID?.rawValue ?? UUID()

        var descriptor = FetchDescriptor<PersistedRunReportItem>(
            predicate: #Predicate { row in
                row.runStartedAt >= after && row.runStartedAt <= before
                    && (!filtersRun || row.runID == runFilter)
                    && (!filtersOutcome || outcomeFilter.contains(row.stateRaw))
                    && (!filtersChangeType || changeTypeFilter.contains(row.changeTypeRaw))
            },
            sortBy: [
                SortDescriptor(\.runStartedAt, order: .reverse),
                SortDescriptor(\.runID),
                SortDescriptor(\.position),
            ]
        )
        if let limit = query.limit, limit > 0 {
            descriptor.fetchLimit = limit
        }

        var items: [RunReportItem] = []
        var skippedCorruptedCount = 0
        for row in try modelContext.fetch(descriptor) {
            guard let item = try? JSONDecoder().decode(RunWorkItem.self, from: row.itemData),
                  item.id == row.itemID
            else {
                skippedCorruptedCount += 1
                log.error("""
                Skipping corrupted report item row \(row.key, privacy: .public) in item query
                """)
                continue
            }
            items.append(RunReportItem(
                runID: RunID(rawValue: row.runID),
                runStartedAt: row.runStartedAt,
                item: item
            ))
        }
        return RunReportItemPage(items: items, skippedCorruptedCount: skippedCorruptedCount)
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
