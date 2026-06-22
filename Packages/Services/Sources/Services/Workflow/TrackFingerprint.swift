import Core
import CryptoKit
import Foundation

/// Builds deterministic hashes for track metadata used by native sync invalidation.
public enum TrackFingerprint {
    /// Returns a stable SHA-256 fingerprint for the fields that affect processing.
    public static func hash(_ track: Track) -> String {
        let year = track.year.map { String($0) } ?? ""
        let releaseYear = track.releaseYear.map { String($0) } ?? ""

        let payloadFields: [String] = [
            track.id,
            track.name,
            track.artist,
            track.album,
            track.albumArtist ?? "",
            track.genre ?? "",
            year,
            releaseYear,
            track.trackStatus ?? "",
        ]
        let payload = payloadFields.joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
