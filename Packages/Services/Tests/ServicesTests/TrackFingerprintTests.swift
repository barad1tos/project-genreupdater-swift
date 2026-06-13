import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("TrackFingerprint")
struct TrackFingerprintTests {
    @Test("same track metadata produces same fingerprint")
    func stableFingerprint() {
        let track = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998,
            dateAdded: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 200),
            trackStatus: "purchased",
            releaseYear: 1998,
            albumArtist: "Artist"
        )

        let firstHash = TrackFingerprint.hash(track)
        let secondHash = TrackFingerprint.hash(track)

        #expect(firstHash == secondHash)
    }

    @Test("processing metadata changes fingerprint")
    func metadataChangesFingerprint() {
        let first = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998
        )
        let second = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Metal",
            year: 1998
        )

        #expect(TrackFingerprint.hash(first) != TrackFingerprint.hash(second))
    }
}
