import Core
import Foundation
import SwiftData

extension StoreSchemaV5 {
    @Model
    final class PersistedScopeCertificate {
        @Attribute(.unique)
        var certificateID: UUID

        var revisionValue: UInt64
        var membershipFingerprint: String
        var testArtistsData: Data
        var fieldSetVersion: UInt16
        var requestedFingerprint: String
        var observedFingerprint: String
        var trackCount: Int
        var observedAt: Date

        init(certificate: ScopeCertificate) throws {
            certificateID = certificate.id
            revisionValue = certificate.revision.value
            membershipFingerprint = certificate.membership.fingerprint
            testArtistsData = try JSONEncoder().encode(certificate.normalizedTestArtists)
            fieldSetVersion = certificate.fieldSet.version
            requestedFingerprint = certificate.requestedFingerprint
            observedFingerprint = certificate.observedFingerprint
            trackCount = certificate.trackCount
            observedAt = certificate.observedAt
        }

        func certificate() throws -> ScopeCertificate {
            try ScopeCertificate(
                id: certificateID,
                revision: MirrorRevision(value: revisionValue),
                membership: MembershipStamp(fingerprint: membershipFingerprint),
                testArtists: JSONDecoder().decode([String].self, from: testArtistsData),
                fieldSet: MirrorFieldSet(version: fieldSetVersion),
                requestedFingerprint: requestedFingerprint,
                observedFingerprint: observedFingerprint,
                trackCount: trackCount,
                observedAt: observedAt
            )
        }
    }
}

typealias PersistedScopeCertificate = StoreSchemaV5.PersistedScopeCertificate
