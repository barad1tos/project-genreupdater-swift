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

    @Test("empty track status does not create a processing metadata change")
    func emptyTrackStatusDoesNotCreateProcessingMetadataChange() {
        let storedWithoutStatus = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998
        )
        let currentWithStatus = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998,
            trackStatus: "matched"
        )
        let storedWithStatus = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998,
            trackStatus: "uploaded"
        )

        #expect(!TrackFingerprint.hasProcessingMetadataChanged(current: currentWithStatus, stored: storedWithoutStatus))
        #expect(TrackFingerprint.hasProcessingMetadataChanged(current: currentWithStatus, stored: storedWithStatus))
    }

    @Test("timestamp-only changes do not affect fingerprint")
    func timestampOnlyChangesDoNotAffectFingerprint() {
        let first = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998,
            dateAdded: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 200)
        )
        let second = Track(
            id: "track-1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1998,
            dateAdded: Date(timeIntervalSince1970: 300),
            lastModified: Date(timeIntervalSince1970: 400)
        )

        #expect(TrackFingerprint.hash(first) == TrackFingerprint.hash(second))
    }
}
