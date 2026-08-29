import Core
import Foundation

/// Immutable evidence that one requested scope was admitted by an exact persisted certificate.
public struct ProcessingAdmission: Codable, Equatable, Sendable {
    public let scopeID: UUID
    public let certificate: ScopeCertificate
    public let mirrorRevision: MirrorRevision
    public let maximumMetadataAge: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case scopeID
        case certificate
        case mirrorRevision
        case maximumMetadataAge
    }

    public var requirement: MirrorRequirement {
        MirrorRequirement(
            testArtists: certificate.normalizedTestArtists,
            fieldSet: certificate.fieldSet,
            maximumMetadataAge: maximumMetadataAge
        )
    }

    public init(
        scopeID: UUID,
        certificate: ScopeCertificate,
        mirrorRevision: MirrorRevision? = nil,
        maximumMetadataAge: TimeInterval?
    ) {
        self.scopeID = scopeID
        self.certificate = certificate
        self.mirrorRevision = mirrorRevision ?? certificate.revision
        self.maximumMetadataAge = maximumMetadataAge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scopeID = try container.decode(UUID.self, forKey: .scopeID)
        certificate = try container.decode(ScopeCertificate.self, forKey: .certificate)
        mirrorRevision = try container.decodeIfPresent(MirrorRevision.self, forKey: .mirrorRevision)
            ?? certificate.revision
        maximumMetadataAge = try container.decodeIfPresent(TimeInterval.self, forKey: .maximumMetadataAge)
    }

    /// Whether this admission certifies the exact captured processing scope.
    public func certifies(scope: ProcessingScopeSnapshot) -> Bool {
        guard scopeID == scope.id,
              scope.hasValidStructure,
              scope.mirrorRevision == mirrorRevision,
              scope.certificateID == certificate.id
        else { return false }

        let requiredArtists = requirement.normalizedTestArtists
        let expectedSource: ProcessingScopeSource = requiredArtists.isEmpty ? .fullLibrary : .testArtists
        guard scope.source == expectedSource else { return false }

        let scopeArtists = MirrorRequirement(
            testArtists: scope.normalizedTestArtists,
            fieldSet: requirement.fieldSet,
            maximumMetadataAge: requirement.maximumMetadataAge
        ).normalizedTestArtists
        guard scopeArtists.count == requiredArtists.count else { return false }
        return zip(scopeArtists, requiredArtists).allSatisfy { scopeArtist, requiredArtist in
            scopeArtist.localizedCaseInsensitiveCompare(requiredArtist) == .orderedSame
        }
    }
}

/// Required relationship between candidate rows and the currently certified scope.
public enum AdmissionTrackMatch: Equatable, Sendable {
    case exactScope
    case subset
}

/// Why current mirror evidence cannot authorize the requested processing work.
public enum ProcessingAdmissionRejection: Error, Equatable, Sendable {
    case mirror(MirrorReadiness)
    case scopeMismatch
    case certificateChanged
    case nonCanonicalTrack(String)
    case duplicateTrack(MusicDatabaseTrackID)
    case trackSetMismatch
}

extension ProcessingAdmissionRejection: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .mirror(readiness):
            Self.mirrorDescription(readiness)
        case .scopeMismatch:
            "The requested processing scope does not match its library evidence. Start the run again."
        case .certificateChanged:
            "The library evidence changed before processing. Scan the library again."
        case let .nonCanonicalTrack(trackID):
            "Track \(trackID) lacks canonical Music database identity. Repair the library mirror and scan again."
        case let .duplicateTrack(databaseID):
            "Track \(databaseID.rawValue) appears more than once in the processing set. "
                + "Repair the library mirror and scan again."
        case .trackSetMismatch:
            "The processing tracks no longer match the certified library scope. Scan the library again."
        }
    }

    private static func mirrorDescription(_ readiness: MirrorReadiness) -> String {
        switch readiness {
        case .ready:
            "The library mirror rejected processing despite being ready. Start the run again."
        case let .stale(reason):
            staleDescription(reason)
        case let .incomplete(reason):
            incompleteDescription(reason)
        case let .unavailable(failure):
            "The library mirror is unavailable (\(failure.category.rawValue)): \(failure.detail). Try the scan again."
        }
    }

    private static func staleDescription(_ reason: StaleMirrorReason) -> String {
        switch reason {
        case .membershipChanged:
            "The Music library changed before processing. Scan the library again."
        case .metadataExpired:
            "The library mirror metadata expired before processing. Scan the library again."
        case .supersededRevision:
            "The library mirror was superseded before processing. Scan the library again."
        }
    }

    private static func incompleteDescription(_ reason: IncompleteMirrorReason) -> String {
        switch reason {
        case .freshObservationRequired:
            "The library mirror has not certified this processing scope. Scan the library again."
        case let .identityMissing(count):
            "The library mirror is missing canonical identity for \(trackCount(count)). "
                + "Repair the library mirror and scan again."
        case let .metadataMissing(count):
            "The library mirror is missing required metadata for \(trackCount(count)). Scan the library again."
        case .narrowedObservation:
            "The library observation did not cover the requested scope. Run a full scan for this scope."
        }
    }

    private static func trackCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "track" : "tracks")"
    }
}

/// Certified processing rows or the typed reason they cannot be used.
public enum ProcessingAdmissionDecision: Equatable, Sendable {
    case admitted(ProcessingAdmission, tracks: [Track])
    case rejected(ProcessingAdmissionRejection)
}

extension TrackStateStore {
    /// Captures durable admission evidence and the exact canonical rows authorized by the current mirror snapshot.
    public func admit(
        scope: ProcessingScopeSnapshot,
        requirement: MirrorRequirement,
        at date: Date
    ) async throws -> ProcessingAdmissionDecision {
        guard scope.matches(requirement) else {
            return .rejected(.scopeMismatch)
        }

        let snapshot = try await loadMirrorSnapshot()
        switch snapshot.admission(for: requirement, at: date) {
        case let .admitted(mirror):
            let isUnboundRequest = scope.mirrorRevision == nil && scope.certificateID == nil
            guard isUnboundRequest || (
                scope.mirrorRevision == snapshot.revision
                    && scope.certificateID == mirror.certificate.id
            ) else {
                return .rejected(.certificateChanged)
            }
            let admission = ProcessingAdmission(
                scopeID: scope.id,
                certificate: mirror.certificate,
                mirrorRevision: snapshot.revision,
                maximumMetadataAge: requirement.maximumMetadataAge
            )
            return .admitted(admission, tracks: mirror.tracks)
        case let .rejected(readiness):
            return .rejected(.mirror(readiness))
        }
    }

    /// Requires the captured certificate to remain current and validates candidate identities against its rows.
    public func revalidate(
        _ admission: ProcessingAdmission,
        candidates: [Track],
        match: AdmissionTrackMatch,
        at date: Date
    ) async throws -> ProcessingAdmissionDecision {
        let snapshot = try await loadMirrorSnapshot()
        let mirror: AdmittedMirror
        switch snapshot.admission(for: admission.requirement, at: date) {
        case let .admitted(currentMirror):
            mirror = currentMirror
        case let .rejected(readiness):
            return .rejected(.mirror(readiness))
        }

        guard snapshot.revision == admission.mirrorRevision,
              mirror.certificate.id == admission.certificate.id
        else {
            return .rejected(.certificateChanged)
        }

        var candidateIDs: Set<MusicDatabaseTrackID> = []
        for track in candidates {
            guard let databaseID = track.databaseID,
                  track.id == databaseID.rawValue
            else {
                return .rejected(.nonCanonicalTrack(track.id))
            }
            guard candidateIDs.insert(databaseID).inserted else {
                return .rejected(.duplicateTrack(databaseID))
            }
        }

        let admittedIDs = Set(mirror.tracks.compactMap(\.databaseID))
        let hasRequiredMatch = switch match {
        case .exactScope:
            candidateIDs == admittedIDs
        case .subset:
            candidateIDs.isSubset(of: admittedIDs)
        }
        guard hasRequiredMatch else {
            return .rejected(.trackSetMismatch)
        }
        return .admitted(admission, tracks: candidates)
    }
}

extension ProcessingScopeSnapshot {
    fileprivate func matches(_ requirement: MirrorRequirement) -> Bool {
        guard hasValidStructure else { return false }
        let expectedSource: ProcessingScopeSource = requirement.normalizedTestArtists.isEmpty
            ? .fullLibrary
            : .testArtists
        guard source == expectedSource else { return false }

        let scopeArtists = MirrorRequirement(
            testArtists: normalizedTestArtists,
            fieldSet: requirement.fieldSet,
            maximumMetadataAge: requirement.maximumMetadataAge
        ).normalizedTestArtists
        guard scopeArtists.count == requirement.normalizedTestArtists.count else { return false }
        return zip(scopeArtists, requirement.normalizedTestArtists).allSatisfy { scopeArtist, requiredArtist in
            scopeArtist.localizedCaseInsensitiveCompare(requiredArtist) == .orderedSame
        }
    }
}
