import Core
import CryptoKit
import Foundation

/// Builds deterministic hashes for track metadata used by native sync invalidation.
public enum TrackFingerprint {
    /// Returns a stable SHA-256 fingerprint for the fields that affect processing.
    public static func hash(_ track: Track) -> String {
        let payload = [
            track.id,
            track.name,
            track.artist,
            track.album,
            track.albumArtist ?? "",
            track.genre ?? "",
            track.year.map(String.init) ?? "",
            track.releaseYear.map(String.init) ?? "",
            track.dateAdded.map(timestamp) ?? "",
            track.lastModified.map(timestamp) ?? "",
            track.trackStatus ?? "",
        ].joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }
}
