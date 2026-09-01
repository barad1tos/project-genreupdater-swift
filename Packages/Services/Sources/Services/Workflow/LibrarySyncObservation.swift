import Core
import Foundation

enum LibrarySyncObservationError: Error, Equatable, LocalizedError, Sendable {
    case nonCanonicalMirror(trackID: String)
    case invalidObservation(detail: String)
    case unresolvedLegacyIdentities(sourceIDs: [String])
    case repairTargetCollision(sourceID: String, targetID: String)

    var errorDescription: String? {
        switch self {
        case let .nonCanonicalMirror(trackID):
            "Stored track \(trackID) does not have canonical Music database identity"
        case let .invalidObservation(detail):
            "Music.app observation is inconsistent: \(detail)"
        case let .unresolvedLegacyIdentities(sourceIDs):
            "Stored tracks have no unique current Music database identity: \(sourceIDs.joined(separator: ", "))"
        case let .repairTargetCollision(sourceID, targetID):
            "Stored track \(sourceID) cannot repair to occupied Music database ID \(targetID)"
        }
    }
}

struct SyncDetection {
    let baseRevision: MirrorRevision
    let observationID: ObservationID
    let result: SyncResult
    let certificateChange: CertificateChange
    let inventoryChange: InventoryChange
    let repairs: [TrackMirrorRepair]
    let retiredAliasIDs: [String]
    let removedAliasTracks: [Track]
    let upserts: [Track]
    let previousTracks: [String: Track]
    let didCompleteForceRefresh: Bool
    let scope: ProcessingScopeSnapshot
    let syncEvidence: MirrorSyncEvidence
    let syncMode: MirrorSyncMode
    let syncCoverage: MirrorSyncCoverage
}

struct DetectionContext {
    let snapshot: TrackMirrorSnapshot
    let repairCandidates: [Track]
    let canonicalStored: [MusicDatabaseTrackID: Track]
    let scopedByID: [MusicDatabaseTrackID: Track]
    let request: LibraryObservationRequest
    let readiness: MirrorReadiness
    let refresh: MetadataRefreshPolicy
    let configuration: LibrarySyncRuntimeConfiguration
}

/// One attempt has a single forward-only path. The outer retry loop creates a new `captured` attempt after revision,
/// census, or source-generation conflicts; no `SyncAttemptState` value transitions backward.
///
/// ```mermaid
/// stateDiagram-v2
///     captured --> loaded: base loaded
///     loaded --> observed: fenced source observation
///     observed --> validated: coverage validated
///     validated --> prepared: commit projected
///     prepared --> committed: compare-and-swap accepted
/// ```
enum SyncAttemptState {
    case captured(SyncAttemptInput)
    case loaded(DetectionContext)
    case observed(DetectionContext, LibraryObservation)
    case validated(DetectionContext, LibraryObservation)
    case prepared(SyncDetection)
    case committed(SyncDetection, MirrorCommitResult, TrackMirrorSnapshot)

    enum Event {
        case loaded(DetectionContext)
        case observed(LibraryObservation)
        case validated
        case prepared(SyncDetection)
        case committed(MirrorCommitResult, TrackMirrorSnapshot)
    }

    func transitioned(by event: Event) throws -> Self {
        switch (self, event) {
        case let (.captured, .loaded(context)):
            .loaded(context)
        case let (.loaded(context), .observed(observation)):
            .observed(context, observation)
        case let (.observed(context, observation), .validated):
            .validated(context, observation)
        case let (.validated, .prepared(detection)):
            .prepared(detection)
        case let (.prepared(detection), .committed(result, snapshot)):
            .committed(detection, result, snapshot)
        default:
            throw LibrarySyncObservationError.invalidObservation(detail: "illegal synchronization transition")
        }
    }
}

extension LibrarySyncService {
    func captureAttemptInput(
        forceMetadataRefresh: Bool = false,
        capturedScope: ProcessingScopeSnapshot? = nil
    ) -> SyncAttemptInput {
        SyncAttemptInput(
            configuration: runtimeConfiguration,
            capturedScope: capturedScope ?? runtimeConfiguration.capturedScope,
            startedAt: currentDate(),
            isForced: forceMetadataRefresh
        )
    }

    func prepareAttempt(_ input: SyncAttemptInput) async throws -> SyncAttemptState {
        var state = SyncAttemptState.captured(input)
        let snapshot = try await trackStore.loadMirrorSnapshot()
        let context = try await detectionContext(
            snapshot: snapshot,
            input: input
        )
        state = try state.transitioned(by: .loaded(context))
        try Task.checkCancellation()
        let observation = try await observer.observe(context.request)
        state = try state.transitioned(by: .observed(observation))
        try Task.checkCancellation()
        try validate(observation, request: context.request)
        state = try state.transitioned(by: .validated)
        let detection = try projectDetection(observation, context: context)
        return try state.transitioned(by: .prepared(detection))
    }

    private func detectionContext(
        snapshot: TrackMirrorSnapshot,
        input: SyncAttemptInput
    ) async throws -> DetectionContext {
        let configuration = input.configuration
        let presentTracks = snapshot.presentTracks
        let scopedPresent = tracksInConfiguredScope(presentTracks, configuration: configuration)
        let repairCandidates = tracksInConfiguredScope(snapshot.repairCandidates, configuration: configuration)
        let canonicalStored = try canonicalMirror(presentTracks)
        let scopedByID = try canonicalMirror(scopedPresent)
        let scope = try processingScope(
            trackCount: scopedPresent.count,
            configuration: configuration,
            capturedScope: input.capturedScope,
            createdAt: input.startedAt
        )
        let shouldForceRefresh = try await shouldRefreshMetadata(
            force: input.isForced,
            configuration: configuration,
            now: input.startedAt
        )
        let refresh: MetadataRefreshPolicy = shouldForceRefresh || !repairCandidates.isEmpty ? .force : .fast
        guard let mirror = LibraryMirrorIndex(tracksByID: scopedByID) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored mirror index is inconsistent")
        }
        guard let inventory = LibraryInventoryIndex(identitiesByID: snapshot.memberIdentities) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored inventory index is inconsistent")
        }
        let requirement = configuration.processingRequirement
        let readiness = snapshot.readiness(for: requirement, at: input.startedAt)
        let previous: LibraryMirrorReference = readiness.isReady ? .verified(mirror) : .initial
        return DetectionContext(
            snapshot: snapshot,
            repairCandidates: repairCandidates,
            canonicalStored: canonicalStored,
            scopedByID: scopedByID,
            request: LibraryObservationRequest(
                scope: scope,
                refresh: refresh,
                previous: previous,
                inventory: inventory
            ),
            readiness: readiness,
            refresh: refresh,
            configuration: configuration
        )
    }

    private func projectDetection(
        _ observation: LibraryObservation,
        context: DetectionContext
    ) throws -> SyncDetection {
        let repair = try planRepair(legacyTracks: context.repairCandidates, observation: observation)
        let removedAliasIDs = Set(repair.retiredAliasIDs + repair.repairs.flatMap(\.sourceIDs))
        let removedAliasTracks = context.repairCandidates.filter { removedAliasIDs.contains($0.id) }
        var mirrorBaseline = context.canonicalStored
        mirrorBaseline.merge(repair.baseline) { existing, _ in existing }
        let classification = try reconcile(
            observation,
            storedByID: mirrorBaseline,
            scopedStoredIDs: Set(context.scopedByID.keys).union(repair.baseline.keys),
            configuration: context.configuration
        )
        let ordinaryUpserts = upsertsExcludingRepairs(classification.upserts, repairedIDs: Set(repair.baseline.keys))
        var projectedMirror = mirrorBaseline
        for track in ordinaryUpserts {
            guard let databaseID = track.databaseID else { continue }
            projectedMirror[databaseID] = track
        }
        let certifiedIDs = Set(projectedMirror.keys).intersection(observation.currentIDs)
        let result = fullMembershipResult(
            classification.result,
            storedIDs: context.snapshot.presentIDs,
            censusIDs: observation.censusIDs
        )
        let isMetadataComplete = hasCompleteMetadata(observation) && observation.identity.isComplete
        let certificateTransition = try certificateChange(for: observation, input: CertificateInput(
            baseRevision: context.snapshot.revision,
            previousReadiness: context.readiness,
            certifiedIDs: certifiedIDs,
            hasTrackMutations: !repair.repairs.isEmpty || !repair.retiredAliasIDs.isEmpty || !ordinaryUpserts.isEmpty,
            configuration: context.configuration
        ))
        let inventoryTransition = try inventoryChange(
            for: observation,
            certificateChange: certificateTransition
        )
        let syncRecord = try syncRecordParts(
            observation: observation,
            certificateChange: certificateTransition,
            context: context,
            isMetadataComplete: isMetadataComplete
        )
        return SyncDetection(
            baseRevision: context.snapshot.revision,
            observationID: ObservationID(),
            result: result,
            certificateChange: certificateTransition,
            inventoryChange: inventoryTransition,
            repairs: repair.repairs,
            retiredAliasIDs: repair.retiredAliasIDs,
            removedAliasTracks: removedAliasTracks,
            upserts: ordinaryUpserts,
            previousTracks: Dictionary(uniqueKeysWithValues: mirrorBaseline.map {
                ($0.key.rawValue, $0.value)
            }),
            didCompleteForceRefresh: context.refresh == .force && isMetadataComplete,
            scope: observation.scope,
            syncEvidence: syncRecord.evidence,
            syncMode: context.refresh == .force ? .force : .fast,
            syncCoverage: syncRecord.coverage
        )
    }

    private func syncRecordParts(
        observation: LibraryObservation,
        certificateChange: CertificateChange,
        context: DetectionContext,
        isMetadataComplete: Bool
    ) throws -> SyncRecordParts {
        let membership = try MembershipFingerprint.make(ids: Array(observation.censusIDs))
        return SyncRecordParts(
            evidence: MirrorSyncEvidence(
                membership: membership,
                scopeID: observation.scope.id,
                certificateID: certificateID(
                    for: certificateChange,
                    previousReadiness: context.readiness
                )
            ),
            coverage: MirrorSyncCoverage(
                identityRequestedCount: observation.identity.requestedIDs.count,
                identityObservedCount: observation.identity.observedIDs.count,
                metadataRequestedCount: observation.metadata.requestedIDs.count,
                metadataObservedCount: observation.metadata.observedIDs.count,
                isMembershipComplete: hasCompleteMembership(observation),
                isIdentityComplete: observation.identity.isComplete,
                isMetadataComplete: isMetadataComplete
            )
        )
    }

    private func certificateID(
        for change: CertificateChange,
        previousReadiness: MirrorReadiness
    ) -> UUID? {
        switch change {
        case let .replace(certificate), let .rebase(certificate):
            certificate.id
        case .preserve:
            if case let .ready(certificate) = previousReadiness {
                certificate.id
            } else {
                nil
            }
        case .invalidate:
            nil
        }
    }

    private func processingScope(
        trackCount: Int,
        configuration: LibrarySyncRuntimeConfiguration,
        capturedScope: ProcessingScopeSnapshot?,
        createdAt: Date
    ) throws -> ProcessingScopeSnapshot {
        if let capturedScope {
            guard capturedScope.hasValidStructure,
                  capturedScope.normalizedTestArtists == configuration.testArtists
            else {
                throw LibrarySyncObservationError.invalidObservation(
                    detail: "captured processing scope does not match synchronization configuration"
                )
            }
            return capturedScope
        }
        return ProcessingScopeSnapshot.capture(
            requestedTestArtists: configuration.testArtists,
            knownTrackCount: trackCount,
            createdAt: createdAt,
            reason: "library sync"
        )
    }

    private func hasCompleteMetadata(_ observation: LibraryObservation) -> Bool {
        observation.metadata.isComplete
            && observation.tracks.allSatisfy { $0.hasCompleteMetadata(for: .processingV1) }
    }

    func hasCompleteMembership(_ observation: LibraryObservation) -> Bool {
        switch (observation.scope.source, observation.membership) {
        case (.fullLibrary, .full):
            true
        case let (.testArtists, .scoped(unobservedIDs)):
            unobservedIDs.isEmpty
        default:
            false
        }
    }

    private func upsertsExcludingRepairs(
        _ upserts: [Track],
        repairedIDs: Set<MusicDatabaseTrackID>
    ) -> [Track] {
        upserts.filter { track in
            guard let databaseID = track.databaseID else { return true }
            return !repairedIDs.contains(databaseID)
        }.sorted { $0.id < $1.id }
    }

    private func inventoryChange(
        for observation: LibraryObservation,
        certificateChange: CertificateChange
    ) throws -> InventoryChange {
        guard certificateChange != .preserve else { return .preserve }
        return try inventoryChange(for: observation)
    }

    private func fullMembershipResult(
        _ scopedResult: SyncResult,
        storedIDs: Set<MusicDatabaseTrackID>,
        censusIDs: Set<MusicDatabaseTrackID>
    ) -> SyncResult {
        let removedIDs = storedIDs.subtracting(censusIDs).sorted { $0.rawValue < $1.rawValue }
        return SyncResult(
            newTracks: scopedResult.newTracks,
            modifiedTracks: scopedResult.modifiedTracks,
            identityChangedTracks: scopedResult.identityChangedTracks,
            refreshedTracks: scopedResult.refreshedTracks,
            removedTrackIDs: removedIDs.map(\.rawValue)
        )
    }

    func inventoryChange(for observation: LibraryObservation) throws -> InventoryChange {
        let censusIDs = observation.censusIDs.sorted { $0.rawValue < $1.rawValue }
        let identities = observation.identities.compactMap { row in
            memberIdentity(from: row, observedAt: observation.observedAt)
        }
        return try .replace(
            stamp: MembershipFingerprint.make(ids: censusIDs),
            ids: censusIDs,
            identities: identities,
            observedAt: observation.observedAt
        )
    }

    private func memberIdentity(from row: LibraryIdentityRow, observedAt: Date) -> MemberIdentity? {
        guard let artist = identityValue(row.artist),
              let albumArtist = identityValue(row.albumArtist)
        else { return nil }
        return MemberIdentity(
            databaseID: row.databaseID,
            artist: artist,
            albumArtist: albumArtist,
            observedAt: observedAt
        )
    }

    private func identityValue(_ observed: Observed<String>) -> String?? {
        switch observed {
        case let .value(value): .some(value)
        case .absent: .some(nil)
        case .unobserved: nil
        }
    }

    private func certificateChange(
        for observation: LibraryObservation,
        input: CertificateInput
    ) throws -> CertificateChange {
        guard input.configuration.albumTargetIdentity == nil else {
            return .invalidate(.narrowedObservation)
        }
        guard hasCompleteMetadata(observation), observation.identity.isComplete else {
            return .invalidate(.incompleteObservation)
        }
        guard hasCompleteMembership(observation) else {
            return .invalidate(.incompleteObservation)
        }

        let membership = try MembershipFingerprint.make(ids: Array(observation.censusIDs))
        if case let .ready(previousCertificate) = input.previousReadiness,
           previousCertificate.membership == membership,
           observation.identity.requestedIDs.isEmpty,
           observation.metadata.requestedIDs.isEmpty,
           !input.hasTrackMutations {
            return .preserve
        }

        guard input.certifiedIDs == observation.currentIDs else {
            return .invalidate(.membershipChanged)
        }
        let scopeFingerprint = try MembershipFingerprint.make(ids: Array(observation.currentIDs)).fingerprint
        return try .replace(ScopeCertificate(
            id: UUID(),
            revision: input.baseRevision.advanced(),
            membership: membership,
            testArtists: observation.scope.normalizedTestArtists,
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: scopeFingerprint,
                observedFingerprint: scopeFingerprint,
                trackCount: observation.currentIDs.count
            ),
            observedAt: observation.observedAt
        ))
    }

    private struct MirrorRepair {
        let repairs: [TrackMirrorRepair]
        let retiredAliasIDs: [String]
        let baseline: [MusicDatabaseTrackID: Track]
    }

    private func planRepair(
        legacyTracks: [Track],
        observation: LibraryObservation
    ) throws -> MirrorRepair {
        guard !legacyTracks.isEmpty else {
            return MirrorRepair(repairs: [], retiredAliasIDs: [], baseline: [:])
        }

        let observedRows = Dictionary(uniqueKeysWithValues: observation.tracks.map { ($0.databaseID, $0) })
        var repairTargets: [String: MusicDatabaseTrackID] = [:]
        var unresolvedTracks: [Track] = []
        for legacy in legacyTracks.sorted(by: { $0.id < $1.id }) {
            if let directID = legacy.databaseID, observedRows[directID] != nil {
                repairTargets[legacy.id] = directID
            } else if legacy.databaseID == nil, let targetID = MusicDatabaseTrackID(rawValue: legacy.id),
                      observedRows[targetID] != nil {
                repairTargets[legacy.id] = targetID
            } else {
                unresolvedTracks.append(legacy)
            }
        }
        if !unresolvedTracks.isEmpty {
            let hasAuthoritativeCandidates = observation.scope.source == .fullLibrary
                && hasCompleteMembership(observation) && observation.identity.isComplete
                && hasCompleteMetadata(observation)
            let observedTracks = hasAuthoritativeCandidates
                ? try observation.tracks.map { try track(from: $0, preserving: nil) }
                : []
            let resolution = TrackIDMapper.resolveAliases(
                sourceTracks: unresolvedTracks,
                targetTracks: observedTracks
            )
            for (sourceID, target) in resolution.matches {
                guard let databaseID = target.databaseID else {
                    throw LibrarySyncObservationError.unresolvedLegacyIdentities(sourceIDs: [sourceID])
                }
                repairTargets[sourceID] = databaseID
            }
            let retiredAliasIDs = hasAuthoritativeCandidates
                ? resolution.ambiguous.keys.sorted() + resolution.unresolved
                : []
            return try makeMirrorRepair(
                legacyTracks: legacyTracks,
                observedRows: observedRows,
                repairTargets: repairTargets,
                retiredAliasIDs: retiredAliasIDs
            )
        }
        return try makeMirrorRepair(
            legacyTracks: legacyTracks,
            observedRows: observedRows,
            repairTargets: repairTargets,
            retiredAliasIDs: []
        )
    }

    private func makeMirrorRepair(
        legacyTracks: [Track],
        observedRows: [MusicDatabaseTrackID: LibraryTrackRow],
        repairTargets: [String: MusicDatabaseTrackID],
        retiredAliasIDs: [String]
    ) throws -> MirrorRepair {
        try validateRepairTargets(repairTargets: repairTargets, legacyTracks: legacyTracks)
        let legacyByID = Dictionary(uniqueKeysWithValues: legacyTracks.map { ($0.id, $0) })
        var groupedSources: [MusicDatabaseTrackID: [String]] = [:]
        for (sourceID, targetID) in repairTargets {
            groupedSources[targetID, default: []].append(sourceID)
        }
        var repairs: [TrackMirrorRepair] = []
        var baseline: [MusicDatabaseTrackID: Track] = [:]
        for targetID in groupedSources.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let sourceIDs = groupedSources[targetID, default: []].sorted()
            guard let sourceID = sourceIDs.first,
                  let legacy = legacyByID[sourceID],
                  let row = observedRows[targetID]
            else {
                throw LibrarySyncObservationError.unresolvedLegacyIdentities(sourceIDs: sourceIDs)
            }
            let target = try track(from: row, preserving: legacy)
            baseline[targetID] = reidentified(legacy, as: targetID)
            repairs.append(TrackMirrorRepair(sourceIDs: sourceIDs, target: target))
        }
        return MirrorRepair(
            repairs: repairs,
            retiredAliasIDs: retiredAliasIDs.sorted(),
            baseline: baseline
        )
    }

    private func validateRepairTargets(
        repairTargets: [String: MusicDatabaseTrackID],
        legacyTracks: [Track]
    ) throws {
        let sourceIDs = Set(legacyTracks.map(\.id))
        for sourceID in repairTargets.keys.sorted() {
            guard let targetID = repairTargets[sourceID] else { continue }
            let isTargetOccupantIncluded = repairTargets[targetID.rawValue] == targetID
            let collidesWithLegacy = targetID.rawValue != sourceID
                && sourceIDs.contains(targetID.rawValue)
                && !isTargetOccupantIncluded
            guard !collidesWithLegacy else {
                throw LibrarySyncObservationError.repairTargetCollision(
                    sourceID: sourceID,
                    targetID: targetID.rawValue
                )
            }
        }
    }

    private func reidentified(_ track: Track, as databaseID: MusicDatabaseTrackID) -> Track {
        Track(
            id: databaseID.rawValue,
            name: track.name,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            year: track.year,
            dateAdded: track.dateAdded,
            lastModified: track.lastModified,
            trackStatus: track.trackStatus,
            originalArtist: track.originalArtist,
            originalAlbum: track.originalAlbum,
            yearBeforeMGU: track.yearBeforeMGU,
            yearSetByMGU: track.yearSetByMGU,
            releaseYear: track.releaseYear,
            originalPosition: track.originalPosition,
            albumArtist: track.albumArtist,
            appleScriptID: databaseID.rawValue
        )
    }

    func canonicalMirror(_ tracks: [Track]) throws -> [MusicDatabaseTrackID: Track] {
        var tracksByID: [MusicDatabaseTrackID: Track] = [:]
        for track in tracks {
            guard let databaseID = track.databaseID,
                  track.id == databaseID.rawValue,
                  tracksByID.updateValue(track, forKey: databaseID) == nil
            else {
                throw LibrarySyncObservationError.nonCanonicalMirror(trackID: track.id)
            }
        }
        return tracksByID
    }

    func validate(_ observation: LibraryObservation, request: LibraryObservationRequest) throws {
        guard observation.scope == request.scope else {
            throw LibrarySyncObservationError.invalidObservation(detail: "scope does not match its request")
        }
        let rowIDs = observation.tracks.map(\.databaseID)
        let rowIDSet = Set(rowIDs)
        guard rowIDSet.count == rowIDs.count else {
            throw LibrarySyncObservationError.invalidObservation(detail: "metadata rows contain duplicate IDs")
        }
        let identityIDs = observation.identities.map(\.databaseID)
        let identityIDSet = Set(identityIDs)
        guard identityIDSet.count == identityIDs.count else {
            throw LibrarySyncObservationError.invalidObservation(detail: "identity rows contain duplicate IDs")
        }
        if request.scope.source == .testArtists {
            guard observation.identities.allSatisfy(\.hasCompleteFields) else {
                throw LibrarySyncObservationError.invalidObservation(
                    detail: "identity rows contain unobserved fields"
                )
            }
            let identitiesByID = Dictionary(uniqueKeysWithValues: observation.identities.map {
                ($0.databaseID, $0)
            })
            let expectedCurrentIDs = request.inventory.admittedIDs(
                censusIDs: observation.censusIDs,
                observed: identitiesByID,
                scope: request.scope
            )
            guard observation.currentIDs == expectedCurrentIDs else {
                throw LibrarySyncObservationError.invalidObservation(
                    detail: "current scope does not match identity classification"
                )
            }
        }
        try validateLookupCoverage(observation, request: request)
        let hasValidMembership = request.scope.source == .fullLibrary
            ? observation.currentIDs == observation.censusIDs
            : observation.currentIDs.isSubset(of: observation.censusIDs)
        let hasExpectedRows = request.scope.source == .fullLibrary
            ? rowIDSet == observation.metadata.observedIDs
            : rowIDSet.isSubset(of: observation.metadata.observedIDs)
        guard hasValidMembership,
              hasExpectedRows,
              observation.metadata.requestedIDs.isSubset(of: observation.censusIDs),
              observation.metadata.observedIDs.isSubset(of: observation.metadata.requestedIDs),
              observation.identity.requestedIDs.isSubset(of: observation.censusIDs),
              observation.identity.observedIDs.isSubset(of: observation.identity.requestedIDs),
              identityIDSet == observation.identity.observedIDs,
              rowIDSet.isSubset(of: observation.currentIDs)
        else {
            throw LibrarySyncObservationError.invalidObservation(detail: "metadata coverage does not match its rows")
        }
        switch observation.membership {
        case .full where request.scope.source != .fullLibrary:
            throw LibrarySyncObservationError.invalidObservation(detail: "full membership has scoped provenance")
        case .scoped where request.scope.source != .testArtists:
            throw LibrarySyncObservationError.invalidObservation(detail: "scoped membership has full provenance")
        default:
            break
        }
    }

    private func validateLookupCoverage(
        _ observation: LibraryObservation,
        request: LibraryObservationRequest
    ) throws {
        let orderedCensusIDs = observation.censusIDs.sorted { $0.rawValue < $1.rawValue }
        let expectedIdentityLookups = request.identityLookupIDs(in: orderedCensusIDs)
        let expectedMetadataLookups = request.metadataLookupIDs(
            in: orderedCensusIDs,
            admittedIDs: observation.currentIDs
        )
        let expectedIdentityIDs = request.reportedIdentityIDs(
            identityLookupIDs: expectedIdentityLookups,
            metadataLookupIDs: expectedMetadataLookups
        )
        guard observation.identity.requestedIDs == expectedIdentityIDs else {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "identity coverage does not match its request"
            )
        }
        guard observation.metadata.requestedIDs == Set(expectedMetadataLookups) else {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "metadata coverage does not match its request"
            )
        }
    }

    private func reconcile(
        _ observation: LibraryObservation,
        storedByID: [MusicDatabaseTrackID: Track],
        scopedStoredIDs: Set<MusicDatabaseTrackID>,
        configuration: LibrarySyncRuntimeConfiguration
    ) throws -> (result: SyncResult, upserts: [Track], removedIDs: [MusicDatabaseTrackID]) {
        var newTracks: [Track] = []
        var modifiedTracks: [Track] = []
        var identityChangedTracks: [Track] = []
        var refreshedTracks: [Track] = []

        for row in observation.tracks.sorted(by: { $0.databaseID.rawValue < $1.databaseID.rawValue }) {
            let stored = storedByID[row.databaseID]
            let current = try track(from: row, preserving: stored)
            guard !tracksAdmittedByRequest([current], configuration: configuration).isEmpty else { continue }
            if let stored {
                if TrackFingerprint.hasProcessingMetadataChanged(current: current, stored: stored) {
                    modifiedTracks.append(current)
                } else if hasIdentityChanged(current: current, stored: stored) {
                    identityChangedTracks.append(current)
                } else if hasSourceMetadataChanged(current: current, stored: stored) {
                    refreshedTracks.append(current)
                }
            } else {
                newTracks.append(current)
            }
        }

        let removedIDs = scopedStoredIDs
            .subtracting(observation.censusIDs)
            .sorted { $0.rawValue < $1.rawValue }
        let upserts = (newTracks + modifiedTracks + identityChangedTracks + refreshedTracks).sorted { $0.id < $1.id }
        return (
            SyncResult(
                newTracks: newTracks.sorted { $0.id < $1.id },
                modifiedTracks: modifiedTracks.sorted { $0.id < $1.id },
                identityChangedTracks: identityChangedTracks.sorted { $0.id < $1.id },
                refreshedTracks: refreshedTracks.sorted { $0.id < $1.id },
                removedTrackIDs: removedIDs.map(\.rawValue)
            ),
            upserts,
            removedIDs
        )
    }

    private func track(from row: LibraryTrackRow, preserving stored: Track?) throws -> Track {
        guard let name = requiredText(row.name, preserving: stored?.name),
              let artist = requiredText(row.artist, preserving: stored?.artist),
              let album = requiredText(row.album, preserving: stored?.album)
        else {
            throw LibrarySyncObservationError.invalidObservation(
                detail: "Metadata row \(row.databaseID.rawValue) omits required text"
            )
        }
        return Track(
            id: row.databaseID.rawValue,
            name: name,
            artist: artist,
            album: album,
            genre: observedValue(row.genre, preserving: stored?.genre),
            year: observedValue(row.editableYear, preserving: stored?.year),
            dateAdded: observedValue(row.dateAdded, preserving: stored?.dateAdded),
            lastModified: observedValue(row.lastModified, preserving: stored?.lastModified),
            trackStatus: observedValue(row.status, preserving: stored?.trackStatus),
            originalArtist: stored?.originalArtist,
            originalAlbum: stored?.originalAlbum,
            yearBeforeMGU: stored?.yearBeforeMGU,
            yearSetByMGU: stored?.yearSetByMGU,
            releaseYear: observedValue(row.releaseYear, preserving: stored?.releaseYear),
            originalPosition: stored?.originalPosition,
            albumArtist: observedValue(row.albumArtist, preserving: stored?.albumArtist),
            appleScriptID: row.databaseID.rawValue
        )
    }

    private func observedValue<Value>(_ observed: Observed<Value>, preserving stored: Value?) -> Value? {
        switch observed {
        case let .value(value): value
        case .absent: nil
        case .unobserved: stored
        }
    }

    private func requiredText(_ observed: Observed<String>, preserving stored: String?) -> String? {
        switch observed {
        case let .value(value): value
        case .absent: ""
        case .unobserved: stored
        }
    }

    private func hasSourceMetadataChanged(current: Track, stored: Track) -> Bool {
        current.name != stored.name
            || current.artist != stored.artist
            || current.album != stored.album
            || current.genre != stored.genre
            || current.year != stored.year
            || current.dateAdded != stored.dateAdded
            || current.trackStatus != stored.trackStatus
            || current.releaseYear != stored.releaseYear
            || current.albumArtist != stored.albumArtist
            || current.appleScriptID != stored.appleScriptID
    }

    private func shouldRefreshMetadata(
        force: Bool,
        configuration: LibrarySyncRuntimeConfiguration,
        now: Date
    ) async throws -> Bool {
        if force {
            return true
        }
        guard let interval = configuration.processingRequirement.maximumMetadataAge,
              let metadata = await librarySnapshotService?.getSnapshotMetadata(),
              let lastForceScanDate = metadata.lastForceScanDate
        else { return false }

        return now.timeIntervalSince(lastForceScanDate) >= interval
    }

    func updateForceScanDate(at date: Date? = nil) async throws {
        guard var metadata = await librarySnapshotService?.getSnapshotMetadata() else { return }
        metadata.lastForceScanDate = date ?? currentDate()
        try await librarySnapshotService?.updateSnapshotMetadata(metadata)
    }
}
