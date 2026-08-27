import Core
import Foundation

/// Immutable evidence that one requested scope was admitted by an exact persisted certificate.
public struct ProcessingAdmission: Codable, Equatable, Sendable {
    public let scopeID: UUID
    public let certificate: ScopeCertificate
    public let maximumMetadataAge: TimeInterval?

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
        maximumMetadataAge: TimeInterval?
    ) {
        self.scopeID = scopeID
        self.certificate = certificate
        self.maximumMetadataAge = maximumMetadataAge
    }
}

/// Required relationship between candidate rows and the currently certified scope.
public enum AdmissionTrackMatch: Equatable, Sendable {
    case exactScope
    case subset
}

/// Why current mirror evidence cannot authorize the requested processing work.
public enum ProcessingAdmissionRejection: Equatable, Sendable {
    case mirror(MirrorReadiness)
    case scopeMismatch
    case certificateChanged
    case nonCanonicalTrack(String)
    case duplicateTrack(MusicDatabaseTrackID)
    case trackSetMismatch
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
            let admission = ProcessingAdmission(
                scopeID: scope.id,
                certificate: mirror.certificate,
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

        guard mirror.certificate.id == admission.certificate.id else {
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
