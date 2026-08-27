import CryptoKit
import Foundation

enum MembershipFingerprintError: Error, Equatable, Sendable {
    case duplicateIDs([MusicDatabaseTrackID])
}

public enum MembershipFingerprint {
    public static func make(ids: [MusicDatabaseTrackID]) throws -> MembershipStamp {
        let duplicates = duplicateIDs(in: ids)
        guard duplicates.isEmpty else {
            throw MembershipFingerprintError.duplicateIDs(duplicates)
        }

        var payload = Data()
        for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
            let bytes = Data(id.rawValue.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(bytes)
        }
        let fingerprint = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return try MembershipStamp(fingerprint: fingerprint)
    }

    private static func duplicateIDs(in ids: [MusicDatabaseTrackID]) -> [MusicDatabaseTrackID] {
        var seen: Set<MusicDatabaseTrackID> = []
        var duplicates: Set<MusicDatabaseTrackID> = []
        for id in ids where !seen.insert(id).inserted {
            duplicates.insert(id)
        }
        return duplicates.sorted { $0.rawValue < $1.rawValue }
    }
}
