import Core
import Foundation

enum LibrarySyncObservationError: Error, Equatable, LocalizedError, Sendable {
    case nonCanonicalMirror(trackID: String)
    case invalidObservation(detail: String)
    case ambiguousLegacyIdentity(sourceID: String, candidateIDs: [String])
    case unresolvedLegacyIdentities(sourceIDs: [String])
    case duplicateRepairTarget(targetID: String, sourceIDs: [String])
    case repairTargetCollision(sourceID: String, targetID: String)

    var errorDescription: String? {
        switch self {
        case let .nonCanonicalMirror(trackID):
            "Stored track \(trackID) does not have canonical Music database identity"
        case let .invalidObservation(detail):
            "Music.app observation is inconsistent: \(detail)"
        case let .ambiguousLegacyIdentity(sourceID, candidateIDs):
            "Stored track \(sourceID) ambiguously matches Music database IDs: \(candidateIDs.joined(separator: ", "))"
        case let .unresolvedLegacyIdentities(sourceIDs):
            "Stored tracks have no unique current Music database identity: \(sourceIDs.joined(separator: ", "))"
        case let .duplicateRepairTarget(targetID, sourceIDs):
            "Stored tracks \(sourceIDs.joined(separator: ", ")) claim the same Music database ID \(targetID)"
        case let .repairTargetCollision(sourceID, targetID):
            "Stored track \(sourceID) cannot repair to occupied Music database ID \(targetID)"
        }
    }
}

struct SyncDetection {
    let baseRevision: MirrorRevision
    let observation: ObservationID
    let result: SyncResult
    let certificateChange: CertificateChange
    let membershipChange: MembershipChange
    let repairs: [TrackMirrorRepair]
    let upserts: [Track]
    let previousTracks: [String: Track]
    let didCompleteForceRefresh: Bool
}

extension LibrarySyncService {
    func detectObservation(forceMetadataRefresh: Bool = false) async throws -> SyncDetection {
        let snapshot = try await trackStore.loadMirrorSnapshot()
        let presentTracks = snapshot.presentTracks
        let scopedPresent = tracksInConfiguredScope(presentTracks)
        let repairCandidates = tracksInConfiguredScope(snapshot.repairCandidates)
        let canonicalStored = try canonicalMirror(presentTracks)
        let scopedByID = try canonicalMirror(scopedPresent)
        let scope = processingScope(trackCount: scopedPresent.count)
        let shouldForceRefresh = try await shouldRefreshMetadata(force: forceMetadataRefresh)
        let refresh: MetadataRefreshPolicy = shouldForceRefresh || !repairCandidates.isEmpty ? .force : .fast
        guard let mirror = LibraryMirrorIndex(tracksByID: scopedByID) else {
            throw LibrarySyncObservationError.invalidObservation(detail: "stored mirror index is inconsistent")
        }
        let requirement = runtimeConfiguration.processingRequirement
        let readiness = snapshot.readiness(for: requirement, at: currentDate())
        let previous: LibraryMirrorReference = readiness.isReady ? .verified(mirror) : .initial
        let request = LibraryObservationRequest(scope: scope, refresh: refresh, previous: previous)
        let observation = try await observer.observe(request)
        try validate(observation, request: request)

        let repair = try planRepair(legacyTracks: repairCandidates, observation: observation)
        var mirrorBaseline = canonicalStored
        mirrorBaseline.merge(repair.baseline) { existing, _ in existing }
        let classification = try reconcile(
            observation,
            storedByID: mirrorBaseline,
            scopedStoredIDs: Set(scopedByID.keys).union(repair.baseline.keys)
        )
        let ordinaryUpserts = upsertsExcludingRepairs(
            classification.upserts,
            repairedIDs: Set(repair.baseline.keys)
        )
        let result = fullMembershipResult(
            classification.result,
            storedIDs: Set(canonicalStored.keys),
            censusIDs: observation.censusIDs
        )
        let isMetadataComplete = hasCompleteMetadata(observation)
        let certificateTransition = try certificateChange(
            for: observation,
            baseRevision: snapshot.revision,
            previousReadiness: readiness,
            hasTrackMutations: !repair.repairs.isEmpty || !ordinaryUpserts.isEmpty,
            isMetadataComplete: isMetadataComplete
        )
        let membershipTransition = try membershipChange(
            for: observation,
            certificateChange: certificateTransition
        )
        return SyncDetection(
            baseRevision: snapshot.revision,
            observation: ObservationID(),
            result: result,
            certificateChange: certificateTransition,
            membershipChange: membershipTransition,
            repairs: repair.repairs,
            upserts: ordinaryUpserts,
            previousTracks: Dictionary(uniqueKeysWithValues: mirrorBaseline.map {
                ($0.key.rawValue, $0.value)
            }),
            didCompleteForceRefresh: refresh == .force && isMetadataComplete
        )
    }

    private func processingScope(trackCount: Int) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: runtimeConfiguration.testArtists,
            knownTrackCount: trackCount,
            createdAt: currentDate(),
            reason: "library sync"
        )
    }

    private func hasCompleteMetadata(_ observation: LibraryObservation) -> Bool {
        observation.metadata.isComplete
            && observation.tracks.allSatisfy { $0.hasCompleteMetadata(for: .processingV1) }
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

    private func membershipChange(
        for observation: LibraryObservation,
        certificateChange: CertificateChange
    ) throws -> MembershipChange {
        guard certificateChange != .preserve else { return .preserve }
        return try membershipChange(for: observation)
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

    func membershipChange(for observation: LibraryObservation) throws -> MembershipChange {
        let censusIDs = observation.censusIDs.sorted { $0.rawValue < $1.rawValue }
        return try .replace(
            stamp: MembershipFingerprint.make(ids: censusIDs),
            ids: censusIDs,
            observedAt: observation.observedAt
        )
    }

    private func certificateChange(
        for observation: LibraryObservation,
        baseRevision: MirrorRevision,
        previousReadiness: MirrorReadiness,
        hasTrackMutations: Bool,
        isMetadataComplete: Bool
    ) throws -> CertificateChange {
        guard runtimeConfiguration.albumTargetIdentity == nil else {
            return .invalidate(.narrowedObservation)
        }
        guard isMetadataComplete else {
            return .invalidate(.incompleteObservation)
        }
        let hasCompleteMembership = switch (observation.scope.source, observation.membership) {
        case (.fullLibrary, .full):
            true
        case let (.testArtists, .scoped(unobservedIDs)):
            unobservedIDs.isEmpty
        default:
            false
        }
        guard hasCompleteMembership else {
            return .invalidate(.incompleteObservation)
        }

        let membership = try MembershipFingerprint.make(ids: Array(observation.censusIDs))
        if case let .ready(previousCertificate) = previousReadiness,
           previousCertificate.membership == membership,
           Set(observation.tracks.map(\.databaseID)) != observation.currentIDs,
           !hasTrackMutations {
            return .preserve
        }

        let observedIDs = Set(observation.tracks.map(\.databaseID))
        guard observedIDs == observation.currentIDs else {
            return .invalidate(.membershipChanged)
        }
        let scopeFingerprint = try MembershipFingerprint.make(ids: Array(observation.currentIDs)).fingerprint
        return try .replace(ScopeCertificate(
            id: UUID(),
            revision: baseRevision.advanced(),
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
        let baseline: [MusicDatabaseTrackID: Track]
    }

    private func planRepair(
        legacyTracks: [Track],
        observation: LibraryObservation
    ) throws -> MirrorRepair {
        guard !legacyTracks.isEmpty else {
            return MirrorRepair(repairs: [], baseline: [:])
        }

        let observedRows = Dictionary(uniqueKeysWithValues: observation.tracks.map { ($0.databaseID, $0) })
        var repairTargets: [String: MusicDatabaseTrackID] = [:]
        var unresolvedTracks: [Track] = []
        for legacy in legacyTracks.sorted(by: { $0.id < $1.id }) {
            if let directID = legacy.databaseID, observedRows[directID] != nil {
                repairTargets[legacy.id] = directID
            } else {
                unresolvedTracks.append(legacy)
            }
        }

        if !unresolvedTracks.isEmpty {
            let observedTracks = try observation.tracks.map { try track(from: $0, preserving: nil) }
            let resolution = TrackIDMapper.resolve(
                sourceTracks: unresolvedTracks,
                targetTracks: observedTracks
            )
            if let sourceID = resolution.ambiguous.keys.min(),
               let candidateIDs = resolution.ambiguous[sourceID] {
                throw LibrarySyncObservationError.ambiguousLegacyIdentity(
                    sourceID: sourceID,
                    candidateIDs: candidateIDs
                )
            }
            guard resolution.unresolved.isEmpty else {
                throw LibrarySyncObservationError.unresolvedLegacyIdentities(
                    sourceIDs: resolution.unresolved
                )
            }
            for (sourceID, target) in resolution.matches {
                guard let databaseID = target.databaseID else {
                    throw LibrarySyncObservationError.unresolvedLegacyIdentities(sourceIDs: [sourceID])
                }
                repairTargets[sourceID] = databaseID
            }
        }

        try validateRepairTargets(
            repairTargets: repairTargets,
            legacyTracks: legacyTracks
        )

        var repairs: [TrackMirrorRepair] = []
        var baseline: [MusicDatabaseTrackID: Track] = [:]
        for legacy in legacyTracks.sorted(by: { $0.id < $1.id }) {
            guard let targetID = repairTargets[legacy.id],
                  let row = observedRows[targetID]
            else {
                throw LibrarySyncObservationError.unresolvedLegacyIdentities(sourceIDs: [legacy.id])
            }
            let target = try track(from: row, preserving: legacy)
            baseline[targetID] = reidentified(legacy, as: targetID)
            repairs.append(TrackMirrorRepair(sourceID: legacy.id, target: target))
        }
        return MirrorRepair(repairs: repairs, baseline: baseline)
    }

    private func validateRepairTargets(
        repairTargets: [String: MusicDatabaseTrackID],
        legacyTracks: [Track]
    ) throws {
        var repairClaims: [MusicDatabaseTrackID: [String]] = [:]
        for (sourceID, targetID) in repairTargets {
            repairClaims[targetID, default: []].append(sourceID)
        }
        if let duplicate = repairClaims
            .compactMap({ target, sources -> (MusicDatabaseTrackID, [String])? in
                guard sources.count > 1 else { return nil }
                return (target, sources.sorted())
            })
            .min(by: { $0.0.rawValue < $1.0.rawValue }) {
            throw LibrarySyncObservationError.duplicateRepairTarget(
                targetID: duplicate.0.rawValue,
                sourceIDs: duplicate.1
            )
        }

        let sourceIDs = Set(legacyTracks.map(\.id))
        for sourceID in repairTargets.keys.sorted() {
            guard let targetID = repairTargets[sourceID] else { continue }
            let collidesWithLegacy = targetID.rawValue != sourceID && sourceIDs.contains(targetID.rawValue)
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

    private func reconcile(
        _ observation: LibraryObservation,
        storedByID: [MusicDatabaseTrackID: Track],
        scopedStoredIDs: Set<MusicDatabaseTrackID>
    ) throws -> (result: SyncResult, upserts: [Track], removedIDs: [MusicDatabaseTrackID]) {
        var newTracks: [Track] = []
        var modifiedTracks: [Track] = []
        var identityChangedTracks: [Track] = []
        var refreshedTracks: [Track] = []

        for row in observation.tracks.sorted(by: { $0.databaseID.rawValue < $1.databaseID.rawValue }) {
            let stored = storedByID[row.databaseID]
            let current = try track(from: row, preserving: stored)
            guard !tracksAdmittedByRequest([current]).isEmpty else { continue }
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

    private func shouldRefreshMetadata(force: Bool) async throws -> Bool {
        if force {
            return true
        }
        guard runtimeConfiguration.forceMetadataScanIntervalDays > 0,
              let metadata = await librarySnapshotService?.getSnapshotMetadata(),
              let lastForceScanDate = metadata.lastForceScanDate
        else { return false }

        let interval = TimeInterval(runtimeConfiguration.forceMetadataScanIntervalDays) * 86400
        return currentDate().timeIntervalSince(lastForceScanDate) >= interval
    }

    func updateForceScanDate() async throws {
        guard var metadata = await librarySnapshotService?.getSnapshotMetadata() else { return }
        metadata.lastForceScanDate = currentDate()
        try await librarySnapshotService?.updateSnapshotMetadata(metadata)
    }
}
