// Phase 2A: Persistence Layer

import Core
import Foundation
import OSLog
import SwiftData

/// Persistent store for track processing state using SwiftData.
///
/// Uses `@ModelActor` for background-safe ModelContext access.
/// Designed for libraries with 30K+ tracks — batch operations use
/// chunked inserts to avoid memory pressure.
@ModelActor
public actor TrackDataStore: TrackStateStore {
    private let log = AppLogger.make(category: "trackstore")

    // MARK: - Initialization

    public func initialize() async throws {
        let repairedCount = try normalizeStoredYears()
        let certificateCount = try initializeMirrorState()
        log.info("SwiftData track store initialized; repaired zero-year rows: \(repairedCount, privacy: .public)")
        log.info(
            "SwiftData track mirror initialized; scope certificates: \(certificateCount, privacy: .public)"
        )
    }

    // MARK: - Read Operations

    public func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try makeMirrorSnapshot()
    }

    private func makeMirrorSnapshot() throws -> TrackMirrorSnapshot {
        let persistedTracks = try fetchPersistedTracks()
        let presentMembers = try fetchPresentMembers()
        let presentIDs = presentMembers.compactMap { MusicDatabaseTrackID(rawValue: $0.databaseID) }
        let presentIDValues = Set(presentIDs.map(\.rawValue))
        let memberIdentities = Dictionary(uniqueKeysWithValues: presentMembers.compactMap { member in
            member.memberIdentity().map { ($0.databaseID, $0) }
        })
        let state = try fetchMirrorState()
        return try TrackMirrorSnapshot(
            revision: state?.revision ?? .initial,
            membershipStamp: MembershipFingerprint.make(ids: presentIDs),
            presentIDs: Set(presentIDs),
            memberIdentities: memberIdentities,
            presentTracks: persistedTracks
                .filter { $0.appleScriptID == $0.trackID && presentIDValues.contains($0.trackID) }
                .map { $0.toTrack() },
            repairCandidates: persistedTracks
                .filter { $0.appleScriptID != $0.trackID }
                .map { $0.toTrack() },
            certificates: fetchCertificates()
        )
    }

    private func fetchPersistedTracks() throws -> [PersistedTrack] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try modelContext.fetch(descriptor)
    }

    private func fetchPresentTracks() throws -> [Track] {
        let presentIDs = try Set(fetchPresentIDs().map(\.rawValue))
        return try fetchPersistedTracks()
            .filter { $0.appleScriptID == $0.trackID && presentIDs.contains($0.trackID) }
            .map { $0.toTrack() }
    }

    private func fetchPresentIDs() throws -> [MusicDatabaseTrackID] {
        try fetchPresentMembers().compactMap { MusicDatabaseTrackID(rawValue: $0.databaseID) }
    }

    private func fetchPresentMembers() throws -> [PersistedLibraryMember] {
        let descriptor = FetchDescriptor<PersistedLibraryMember>(
            predicate: #Predicate { $0.isPresent }
        )
        let members = try modelContext.fetch(descriptor)
        let invalidIDs = members.compactMap { member in
            MusicDatabaseTrackID(rawValue: member.databaseID) == nil ? member.databaseID : nil
        }.sorted()
        guard invalidIDs.isEmpty else {
            throw TrackStoreError.invalidMembershipIDs(ids: invalidIDs)
        }
        return members
    }

    public func getTrack(byID id: String) async throws -> Track? {
        let memberDescriptor = FetchDescriptor<PersistedLibraryMember>(
            predicate: #Predicate { $0.databaseID == id && $0.isPresent }
        )
        guard try modelContext.fetch(memberDescriptor).first != nil else { return nil }
        return try fetchTrack(byID: id)?.toTrack()
    }

    public func getHistoricalTrack(byID id: String) async throws -> Track? {
        try fetchTrack(byID: id)?.toTrack()
    }

    private func fetchTrack(byID id: String) throws -> PersistedTrack? {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    public func getUnprocessedTracks() async throws -> [Track] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate {
                $0.genreUpdated == false || $0.yearUpdated == false
            }
        )
        let presentIDs = try Set(fetchPresentIDs().map(\.rawValue))
        return try modelContext.fetch(descriptor)
            .filter { $0.appleScriptID == $0.trackID && presentIDs.contains($0.trackID) }
            .map { $0.toTrack() }
    }

    public func trackCount() async throws -> Int {
        try fetchPresentTracks().count
    }

    // MARK: - Write Operations

    @discardableResult
    public func commitMirror(_ commit: MirrorCommit) async throws -> MirrorCommitResult {
        try Task.checkCancellation()
        var membershipDelta = MembershipDelta()
        var committedRevision = commit.baseRevision
        var committedSnapshot: TrackMirrorSnapshot?
        do {
            try modelContext.transaction {
                let mirrorState: PersistedMirrorState
                if let storedMirrorState = try fetchMirrorState() {
                    mirrorState = storedMirrorState
                } else {
                    let newMirrorState = PersistedMirrorState()
                    modelContext.insert(newMirrorState)
                    mirrorState = newMirrorState
                }
                guard mirrorState.revision == commit.baseRevision else {
                    throw MirrorRevisionConflict(expected: commit.baseRevision, actual: mirrorState.revision)
                }

                let transactionPlan = try Self.validate(commit)
                let nextRevision = try mirrorState.revision.advanced()
                try applyTrackChanges(transactionPlan, upserts: commit.upserts)
                membershipDelta = try applyInventory(transactionPlan.inventory, revision: nextRevision)
                let membership = try MembershipFingerprint.make(ids: fetchPresentIDs())
                try validateSyncRecord(
                    commit.syncRecord,
                    commit: commit,
                    nextRevision: nextRevision,
                    membership: membership
                )
                try applyCertificates(commit.certificates, revision: nextRevision, membership: membership)
                if let record = commit.syncRecord {
                    modelContext.insert(PersistedSyncRecord(record: record, completedAt: Date()))
                    if let limit = commit.syncRecordLimit {
                        try pruneSyncRecords(keeping: limit)
                    }
                }
                committedRevision = try mirrorState.advanceRevision()
                committedSnapshot = try makeMirrorSnapshot()
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        log.info("Applied mirror repairs: \(commit.repairs.count, privacy: .public)")
        log
            .info(
                "Applied mirror upserts: \(commit.upserts.count, privacy: .public); membership additions: \(membershipDelta.added, privacy: .public); tombstones: \(membershipDelta.removed, privacy: .public); resurrections: \(membershipDelta.resurrected, privacy: .public)"
            )
        guard let committedSnapshot else {
            throw TrackStoreError.invalidSyncRecord
        }
        return MirrorCommitResult(revision: committedRevision, snapshot: committedSnapshot)
    }

    private func validateSyncRecord(
        _ record: MirrorSyncRecord?,
        commit: MirrorCommit,
        nextRevision: MirrorRevision,
        membership: MembershipStamp
    ) throws {
        guard let record else { return }
        guard record.observation == commit.observation,
              record.revisions.base == commit.baseRevision,
              record.revisions.committed == nextRevision,
              record.evidence.membership == membership,
              try isValidCertificateEvidence(record, change: commit.certificates)
        else {
            throw TrackStoreError.invalidSyncRecord
        }
    }

    private func pruneSyncRecords(keeping limit: Int) throws {
        let descriptor = FetchDescriptor<PersistedSyncRecord>(
            sortBy: [SortDescriptor(\.committedRevisionValue, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        for record in records.dropFirst(max(1, limit)) {
            modelContext.delete(record)
        }
    }

    private func isValidCertificateEvidence(
        _ record: MirrorSyncRecord,
        change: CertificateChange
    ) throws -> Bool {
        switch change {
        case let .replace(certificate), let .rebase(certificate):
            return record.evidence.certificateID == certificate.id
        case .invalidate:
            return record.evidence.certificateID == nil
        case .preserve where record.mode == .membershipOnly:
            return record.evidence.certificateID == nil
        case .preserve:
            guard let certificateID = record.evidence.certificateID else { return false }
            return try fetchCertificates().contains { $0.id == certificateID }
        }
    }

    private func applyTrackChanges(_ plan: MirrorPlan, upserts: [Track]) throws {
        guard !plan.repairs.isEmpty || !upserts.isEmpty else { return }

        let storedTracks = try modelContext.fetch(FetchDescriptor<PersistedTrack>())
        let storedState = try Self.validateStored(plan, tracks: storedTracks)
        let history = plan.repairs.isEmpty
            ? []
            : try modelContext.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        for repair in plan.repairs {
            try Self.applyRepair(repair, state: storedState, history: history, modelContext: modelContext)
        }
        for (track, databaseID) in zip(upserts, plan.upsertIDs) {
            if let persistedTrack = storedState.canonicalByID[databaseID] {
                persistedTrack.updateMirror(from: track, databaseID: databaseID)
            } else {
                modelContext.insert(PersistedTrack(mirror: track, databaseID: databaseID))
            }
        }
    }

    public func persistAppliedChange(_ change: ChangeLogEntry) async throws {
        do {
            let descriptor = FetchDescriptor<PersistedTrack>(
                predicate: #Predicate { $0.trackID == change.trackID }
            )
            guard let persisted = try modelContext.fetch(descriptor).first else {
                throw TrackStoreError.missingTrack(id: change.trackID)
            }

            let updated = try persisted.toTrack().applying(change)
            persisted.update(from: updated)
            switch change.changeType {
            case .genreUpdate:
                persisted.genreUpdated = true
            case .yearUpdate, .yearRevert:
                persisted.yearUpdated = true
            case .trackCleaning, .albumCleaning, .artistRename:
                break
            }
            persisted.processedDate = .now

            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func normalizeStoredYears() throws -> Int {
        let missingValue = MusicAppYear.missingValue
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate {
                $0.year == missingValue || $0.releaseYear == missingValue
            }
        )
        let tracks = try modelContext.fetch(descriptor)
        guard !tracks.isEmpty else { return 0 }

        do {
            for track in tracks {
                track.year = MusicAppYear.normalized(track.year)
                track.releaseYear = MusicAppYear.normalized(track.releaseYear)
            }
            try modelContext.save()
            return tracks.count
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func initializeMirrorState() throws -> Int {
        if try fetchMirrorState() != nil {
            return try modelContext.fetchCount(FetchDescriptor<PersistedScopeCertificate>())
        }

        modelContext.insert(PersistedMirrorState())
        try modelContext.save()
        return 0
    }

    private func fetchMirrorState() throws -> PersistedMirrorState? {
        let key = PersistedMirrorState.primaryKey
        let descriptor = FetchDescriptor<PersistedMirrorState>(
            predicate: #Predicate { $0.key == key }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchCertificates() throws -> [ScopeCertificate] {
        try modelContext.fetch(FetchDescriptor<PersistedScopeCertificate>())
            .map { try $0.certificate() }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func applyCertificates(
        _ change: CertificateChange,
        revision: MirrorRevision,
        membership: MembershipStamp
    ) throws {
        switch change {
        case .preserve:
            return
        case .invalidate:
            try deleteCertificates()
        case let .replace(certificate), let .rebase(certificate):
            try Self.validate(certificate, revision: revision, membership: membership)
            try deleteCertificates()
            try modelContext.insert(PersistedScopeCertificate(certificate: certificate))
        }
    }

    private func deleteCertificates() throws {
        for certificate in try modelContext.fetch(FetchDescriptor<PersistedScopeCertificate>()) {
            modelContext.delete(certificate)
        }
    }

    private func membershipByID() throws -> [String: PersistedLibraryMember] {
        let members = try modelContext.fetch(FetchDescriptor<PersistedLibraryMember>())
        return Dictionary(uniqueKeysWithValues: members.map { ($0.databaseID, $0) })
    }

    private struct MembershipDelta {
        var added = 0
        var removed = 0
        var resurrected = 0
    }

    private func applyInventory(
        _ change: ValidatedInventoryChange,
        revision: MirrorRevision
    ) throws -> MembershipDelta {
        guard case let .replace(stamp, ids, identities, observedAt) = change else {
            return MembershipDelta()
        }

        let stored = try membershipByID()
        let identitiesByID = Dictionary(uniqueKeysWithValues: identities.map { ($0.databaseID, $0) })
        let currentIDs = Set(ids.map(\.rawValue))
        var delta = MembershipDelta()
        for id in ids {
            if let member = stored[id.rawValue] {
                guard !member.isPresent else {
                    member.markSeen(stamp: stamp)
                    if let identity = identitiesByID[id] {
                        member.apply(identity: identity, revision: revision)
                    }
                    continue
                }
                member.markPresent(stamp: stamp)
                if let identity = identitiesByID[id] {
                    member.apply(identity: identity, revision: revision)
                }
                delta.resurrected += 1
            } else {
                let member = PersistedLibraryMember(
                    databaseID: id.rawValue,
                    isPresent: true,
                    firstSeenRevisionValue: revision.value,
                    lastSeenFingerprint: stamp.fingerprint
                )
                if let identity = identitiesByID[id] {
                    member.apply(identity: identity, revision: revision)
                }
                modelContext.insert(member)
                delta.added += 1
            }
        }
        for member in stored.values where member.isPresent && !currentIDs.contains(member.databaseID) {
            member.markRemoved(revision: revision, at: observedAt)
            delta.removed += 1
        }
        return delta
    }

    private static func duplicateIDs(in ids: [MusicDatabaseTrackID]) -> [MusicDatabaseTrackID] {
        var seen = Set<MusicDatabaseTrackID>()
        var duplicates = Set<MusicDatabaseTrackID>()
        for id in ids where !seen.insert(id).inserted {
            duplicates.insert(id)
        }
        return duplicates.sorted { $0.rawValue < $1.rawValue }
    }

    private static func canonicalIDs(for tracks: [Track]) throws -> [MusicDatabaseTrackID] {
        try tracks.map { track in
            guard let databaseID = track.databaseID else {
                throw TrackStoreError.missingDatabaseID(trackID: track.id)
            }
            guard track.id == databaseID.rawValue else {
                throw TrackStoreError.nonCanonicalTrack(trackID: track.id, databaseID: databaseID)
            }
            return databaseID
        }
    }

    private struct ValidatedRepair {
        let sourceID: String
        let targetID: MusicDatabaseTrackID
        let track: Track
    }

    private struct MirrorPlan {
        let repairs: [ValidatedRepair]
        let upsertIDs: [MusicDatabaseTrackID]
        let inventory: ValidatedInventoryChange
    }

    private enum ValidatedInventoryChange {
        case preserve
        case replace(
            stamp: MembershipStamp,
            ids: [MusicDatabaseTrackID],
            identities: [MemberIdentity],
            observedAt: Date
        )
    }

    private struct StoredMirrorState {
        let byID: [String: PersistedTrack]
        let canonicalByID: [MusicDatabaseTrackID: PersistedTrack]
    }

    private static func validate(_ commit: MirrorCommit) throws -> MirrorPlan {
        try validateCertificateTransition(commit)
        let repairs = try validatedRepairs(commit.repairs)
        let upsertIDs = try canonicalIDs(for: commit.upserts)
        let duplicateUpserts = duplicateIDs(in: upsertIDs)
        guard duplicateUpserts.isEmpty else {
            throw TrackStoreError.duplicateUpserts(ids: duplicateUpserts)
        }

        let inventory = try validatedInventory(commit.inventoryChange)
        let overlappingIDs = overlapIDs(repairs: repairs, upserts: upsertIDs)
        guard overlappingIDs.isEmpty else {
            throw TrackStoreError.identityOverlap(ids: overlappingIDs)
        }
        if case let .replace(_, ids, _, _) = inventory {
            let presentIDs = Set(ids)
            let operationIDs = Set(upsertIDs).union(repairs.map(\.targetID))
            let outsideMembership = operationIDs.subtracting(presentIDs)
                .sorted { $0.rawValue < $1.rawValue }
            guard outsideMembership.isEmpty else {
                throw TrackStoreError.operationsOutsideMembership(ids: outsideMembership)
            }
        }
        return MirrorPlan(repairs: repairs, upsertIDs: upsertIDs, inventory: inventory)
    }

    private static func validateCertificateTransition(_ commit: MirrorCommit) throws {
        switch commit.certificates {
        case .preserve:
            guard commit.inventoryChange == .preserve,
                  commit.repairs.isEmpty,
                  commit.upserts.isEmpty
            else {
                throw TrackStoreError.unsafeCertificatePreserve
            }
        case .rebase:
            throw TrackStoreError.unprovenCertificateRebase
        case .invalidate, .replace:
            break
        }
    }

    private static func validate(
        _ certificate: ScopeCertificate,
        revision: MirrorRevision,
        membership: MembershipStamp
    ) throws {
        guard certificate.revision == revision else {
            throw TrackStoreError.certificateRevisionMismatch(expected: revision, actual: certificate.revision)
        }
        guard certificate.membership == membership else {
            throw TrackStoreError.certificateMembershipMismatch(expected: membership, actual: certificate.membership)
        }
        guard certificate.requestedFingerprint == certificate.observedFingerprint else {
            throw TrackStoreError.incompleteCertificate
        }
        guard certificate.trackCount >= 0 else {
            throw TrackStoreError.invalidCertificateTrackCount(certificate.trackCount)
        }
    }

    private static func validatedInventory(_ change: InventoryChange) throws -> ValidatedInventoryChange {
        switch change {
        case .preserve:
            return .preserve
        case let .replace(stamp, ids, identities, observedAt):
            let duplicates = duplicateIDs(in: ids)
            guard duplicates.isEmpty else {
                throw TrackStoreError.duplicateMembershipIDs(ids: duplicates)
            }
            let duplicateIdentities = duplicateIDs(in: identities.map(\.databaseID))
            guard duplicateIdentities.isEmpty else {
                throw TrackStoreError.duplicateMembershipIDs(ids: duplicateIdentities)
            }
            let expected = try MembershipFingerprint.make(ids: ids)
            guard stamp == expected else {
                throw TrackStoreError.membershipStampMismatch(expected: expected, actual: stamp)
            }
            let membershipIDs = Set(ids)
            let identityIDs = Set(identities.map(\.databaseID))
            let identitiesOutsideMembership = identityIDs.subtracting(membershipIDs)
                .sorted { $0.rawValue < $1.rawValue }
            guard identitiesOutsideMembership.isEmpty else {
                throw TrackStoreError.operationsOutsideMembership(ids: identitiesOutsideMembership)
            }
            return .replace(
                stamp: stamp,
                ids: ids.sorted { $0.rawValue < $1.rawValue },
                identities: identities.sorted { $0.databaseID.rawValue < $1.databaseID.rawValue },
                observedAt: observedAt
            )
        }
    }

    private static func validatedRepairs(_ repairs: [TrackMirrorRepair]) throws -> [ValidatedRepair] {
        let emptySource = repairs.contains { $0.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !emptySource else { throw TrackStoreError.emptySource }

        let duplicateSources = duplicateStrings(in: repairs.map(\.sourceID))
        guard duplicateSources.isEmpty else {
            throw TrackStoreError.duplicateRepairSources(ids: duplicateSources)
        }

        let targetIDs = try canonicalIDs(for: repairs.map(\.target))
        let duplicateTargets = duplicateIDs(in: targetIDs)
        guard duplicateTargets.isEmpty else {
            throw TrackStoreError.duplicateRepairTargets(ids: duplicateTargets)
        }

        return zip(repairs, targetIDs).map { repair, targetID in
            ValidatedRepair(sourceID: repair.sourceID, targetID: targetID, track: repair.target)
        }
    }

    private static func overlapIDs(
        repairs: [ValidatedRepair],
        upserts: [MusicDatabaseTrackID]
    ) -> [MusicDatabaseTrackID] {
        let targets = Set(repairs.map(\.targetID))
        let upsertSet = Set(upserts)
        let overlaps = targets.intersection(upsertSet)
        return overlaps.sorted { $0.rawValue < $1.rawValue }
    }

    @discardableResult
    private static func validateStored(_ plan: MirrorPlan, tracks: [PersistedTrack]) throws -> StoredMirrorState {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackID, $0) })
        for repair in plan.repairs {
            let source = byID[repair.sourceID]
            let target = byID[repair.targetID.rawValue]
            guard source != nil || target?.isCanonical(databaseID: repair.targetID) == true else {
                throw TrackStoreError.missingSource(id: repair.sourceID)
            }
            if let source, repair.sourceID == repair.targetID.rawValue {
                guard source.appleScriptID != source.trackID else {
                    throw TrackStoreError.redundantRepair(id: repair.targetID)
                }
            } else if let target, !target.isCanonical(databaseID: repair.targetID) {
                throw TrackStoreError.targetExists(id: repair.targetID)
            }
        }

        let operationIDs = Set(plan.upsertIDs)
        let canonicalByID = try indexCanonicalTracks(tracks, operationIDs: operationIDs)
        return StoredMirrorState(byID: byID, canonicalByID: canonicalByID)
    }

    private static func applyRepair(
        _ repair: ValidatedRepair,
        state: StoredMirrorState,
        history: [PersistedChangeLogEntry],
        modelContext: ModelContext
    ) throws {
        let source = state.byID[repair.sourceID]
        let target = state.canonicalByID[repair.targetID]
        let sourceHistory = history.filter { entry in
            entry.trackID == repair.sourceID || entry.track === source
        }
        let persistedTrack: PersistedTrack
        let sourceToDelete: PersistedTrack?
        if let source, let target, source !== target {
            target.mergeRepair(source, with: repair.track, databaseID: repair.targetID)
            persistedTrack = target
            sourceToDelete = source
        } else if let source {
            source.repairMirror(with: repair.track, databaseID: repair.targetID)
            persistedTrack = source
            sourceToDelete = nil
        } else if let target {
            target.updateMirror(from: repair.track, databaseID: repair.targetID)
            persistedTrack = target
            sourceToDelete = nil
        } else {
            throw TrackStoreError.missingSource(id: repair.sourceID)
        }
        for entry in sourceHistory {
            entry.trackID = repair.targetID.rawValue
            entry.track = persistedTrack
        }
        if let sourceToDelete {
            sourceToDelete.changeLog.removeAll()
            modelContext.delete(sourceToDelete)
        }
    }

    private static func indexCanonicalTracks(
        _ tracks: [PersistedTrack],
        operationIDs: Set<MusicDatabaseTrackID>
    ) throws -> [MusicDatabaseTrackID: PersistedTrack] {
        var canonicalByID: [MusicDatabaseTrackID: PersistedTrack] = [:]
        var collisions = Set<MusicDatabaseTrackID>()
        for track in tracks {
            guard let databaseID = MusicDatabaseTrackID(rawValue: track.trackID) else { continue }
            guard track.appleScriptID == track.trackID else {
                if operationIDs.contains(databaseID) {
                    collisions.insert(databaseID)
                }
                continue
            }
            canonicalByID[databaseID] = track
        }
        guard collisions.isEmpty else {
            throw TrackStoreError.identityCollisions(ids: collisions.sorted { $0.rawValue < $1.rawValue })
        }
        return canonicalByID
    }

    private static func duplicateStrings(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }
}

// MARK: - Factory

extension TrackDataStore {
    /// Create a track store with the default shared ModelContainer.
    public static func createDefault() throws -> TrackDataStore {
        let container = try ModelContainerFactory.create()
        return TrackDataStore(modelContainer: container)
    }
}
