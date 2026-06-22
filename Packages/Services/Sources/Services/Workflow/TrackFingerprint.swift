import Core
import CryptoKit
import Foundation

/// Builds deterministic hashes for track metadata used by native sync invalidation.
public enum TrackFingerprint {
    /// Returns a stable SHA-256 fingerprint for the fields that affect processing.
    public static func hash(_ track: Track) -> String {
        hash(track, includesTrackStatus: true)
    }

    /// Returns true when the current track changed in metadata relevant to processing.
    public static func hasProcessingMetadataChanged(current: Track, stored: Track) -> Bool {
        guard hash(current, includesTrackStatus: false) == hash(stored, includesTrackStatus: false) else {
            return true
        }

        guard let currentTrackStatus = current.trackStatus?.nilIfEmpty,
              let storedTrackStatus = stored.trackStatus?.nilIfEmpty
        else {
            return false
        }
        return currentTrackStatus != storedTrackStatus
    }

    private static func hash(_ track: Track, includesTrackStatus: Bool) -> String {
        let year = track.year.map { String($0) } ?? ""
        let releaseYear = track.releaseYear.map { String($0) } ?? ""

        var payloadFields: [String] = [
            track.id,
            track.name,
            track.artist,
            track.album,
            track.albumArtist ?? "",
            track.genre ?? "",
            year,
            releaseYear,
        ]
        if includesTrackStatus {
            payloadFields.append(track.trackStatus ?? "")
        }
        let payload = payloadFields.joined(separator: "\u{1F}")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
