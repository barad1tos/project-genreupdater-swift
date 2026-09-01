import Foundation
import SwiftData

extension RunRecordDataStore {
    public func recoveryRecords() async throws -> RunReportPage {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try makePage(from: modelContext.fetch(descriptor)) {
            $0.finishedAt == nil && (RunIntent(rawValue: $0.intentRaw)?.isMutating ?? false)
        }
    }

    public func reports(matching query: RunReportQuery) async throws -> RunReportPage {
        let after = query.startedAfter ?? Date.distantPast
        let before = query.startedBefore ?? Date.distantFuture
        let stateFilter = Set((query.states ?? []).map(\.rawValue))
        let filtersState = !stateFilter.isEmpty
        let triggerFilter = query.trigger?.rawValue ?? ""
        let filtersTrigger = !triggerFilter.isEmpty
        let intentFilter = query.intent?.rawValue ?? ""
        let filtersIntent = !intentFilter.isEmpty

        var descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: #Predicate { row in
                row.startedAt >= after && row.startedAt <= before
                    && (!filtersState || stateFilter.contains(row.stateRaw))
                    && (!filtersTrigger || row.triggerRaw == triggerFilter)
                    && (!filtersIntent || row.intentRaw == intentFilter)
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit = query.limit, limit > 0 {
            descriptor.fetchLimit = limit
        }

        return try makePage(from: modelContext.fetch(descriptor))
    }

    public func retainedPlanIDs() async throws -> Set<FixPlanID>? {
        var planIDs = Set<FixPlanID>()
        for row in try modelContext.fetch(FetchDescriptor<PersistedRunRecord>()) {
            if let record = try? makeRecord(from: row) {
                if let planID = record.writeTarget?.planID {
                    planIDs.insert(planID)
                }
                continue
            }
            switch planReference(of: row) {
            case let .plan(planID):
                planIDs.insert(planID)
            case .none:
                continue
            case .unreadable:
                log.error("""
                Fix-plan retention fails closed: run \(row.runID, privacy: .public) has an \
                unreadable plan reference
                """)
                return nil
            }
        }
        return planIDs
    }

    private enum PlanReference {
        case none
        case plan(FixPlanID)
        case unreadable
    }

    /// Best-effort plan reference of a row `makeRecord` rejected, mirroring
    /// `continuationReference`: a strict payload, a per-field salvage, or a
    /// forward-schema salvage all name their plan trustworthily — the repair
    /// paths rebuild payloads from the same sources. Only garbage bytes and
    /// unsalvageable rows are unreadable.
    private func planReference(of row: PersistedRunRecord) -> PlanReference {
        do {
            let decoded = try RunPayloadCodec.decodeForRecovery(from: row)
            if let payload = decoded.payload {
                return payload.writeTarget.map { .plan($0.planID) } ?? .none
            }
            if let fallback = decoded.fallback {
                return fallback.writeTarget.map { .plan($0.planID) } ?? .none
            }
            return .unreadable
        } catch {
            if let salvage = try? JSONDecoder().decode(RecoveryPayload.self, from: row.transitionsData) {
                return salvage.writeTarget.map { .plan($0.planID) } ?? .none
            }
            return .unreadable
        }
    }

    public func resolvedRecoveryRun(recoveryID: UUID) async throws -> RunID? {
        // The newest DECODABLE terminal claim-carrier wins — the exact filter
        // the replaced full-history scan applied: a row whose payload no
        // longer decodes never resolves a claim, it surfaces for repair
        // instead. The column arm narrows to stamped claim rows. The legacy
        // arm covers pre-column rows (nil column, claim only in the payload):
        // every non-recovery run also persists a nil column, so the predicate
        // additionally narrows to write intent — claims are only ever
        // persisted on writeFixes runs — and the scan stops once rows are no
        // newer than the column hit, which already wins ties.
        let writeIntent = RunIntent.writeFixes.rawValue
        let columnHit = try resolvedClaimCarrier(
            matching: #Predicate { $0.recoveryID == recoveryID && $0.finishedAt != nil },
            claim: recoveryID
        )
        let legacyHit = try resolvedClaimCarrier(
            matching: #Predicate {
                $0.recoveryID == nil && $0.finishedAt != nil && $0.intentRaw == writeIntent
            },
            claim: recoveryID,
            newerThan: columnHit?.startedAt
        )
        switch (columnHit, legacyHit) {
        case let (column?, legacy?):
            return legacy.startedAt > column.startedAt ? legacy.runID : column.runID
        case let (column?, nil):
            return column.runID
        case let (nil, legacy?):
            return legacy.runID
        case (nil, nil):
            return nil
        }
    }

    private func resolvedClaimCarrier(
        matching predicate: Predicate<PersistedRunRecord>,
        claim recoveryID: UUID,
        newerThan cutoff: Date? = nil
    ) throws -> (runID: RunID, startedAt: Date)? {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        for row in try modelContext.fetch(descriptor) {
            if let cutoff, row.startedAt <= cutoff {
                return nil
            }
            guard let record = try? makeRecord(from: row) else {
                log.error("""
                Skipping undecodable run record \(row.runID, privacy: .public) in recovery \
                resolution lookup; it cannot resolve a claim
                """)
                continue
            }
            if record.recoveryID == recoveryID, record.finishedAt != nil {
                return (record.runID, record.startedAt)
            }
        }
        return nil
    }

    public func continuations(of runID: RunID) async throws -> [RunID] {
        // Reverse lineage over decodable rows only. A nil column means BOTH
        // "pre-column row" and "unlinked run", so the payload arm scans every
        // unlinked write run forever — it does NOT shrink over time. The scan
        // is user-action-bound (one call per detail-card open), skips the
        // per-row child-item fetch, and narrows to write intent (the
        // continuation request factory is the only producer of
        // `continuesRunID` and always writes). Removing the arm behind a
        // one-shot column backfill is ledgered.
        let sourceID = runID.rawValue
        let writeIntent = RunIntent.writeFixes.rawValue
        let columnHits = try continuationCarriers(
            matching: #Predicate { $0.continuesRunID == sourceID },
            source: runID
        )
        let payloadHits = try continuationCarriers(
            matching: #Predicate { $0.continuesRunID == nil && $0.intentRaw == writeIntent },
            source: runID
        )
        return (columnHits + payloadHits)
            .sorted { left, right in
                if left.startedAt != right.startedAt {
                    return left.startedAt > right.startedAt
                }
                // Deterministic tie order: the detail is an immutable
                // projection and must not flip between opens.
                return left.runID.rawValue.uuidString < right.runID.rawValue.uuidString
            }
            .map(\.runID)
    }

    private func continuationCarriers(
        matching predicate: Predicate<PersistedRunRecord>,
        source runID: RunID
    ) throws -> [(runID: RunID, startedAt: Date)] {
        let descriptor = FetchDescriptor<PersistedRunRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        var carriers: [(runID: RunID, startedAt: Date)] = []
        for row in try modelContext.fetch(descriptor) {
            // Lineage needs identity fields only; skipping the stored
            // work-item reconciliation avoids a child fetch per row.
            guard let record = try? makeRecord(from: row, loadsStoredWorkItems: false) else {
                log.error("""
                Skipping undecodable run record \(row.runID, privacy: .public) in continuation \
                lookup; its lineage (if any) is not listed
                """)
                continue
            }
            if record.continuesRunID == runID {
                carriers.append((record.runID, record.startedAt))
            }
        }
        return carriers
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
