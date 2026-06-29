import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibraryReadProvider")
struct LibraryReadProviderTests {
    @Test("Snapshot preserves tracks and scan date")
    func snapshotPreservesTracksAndScanDate() {
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tracks = [
            Track(id: "MK-1", name: "Battery", artist: "Metallica", album: "Master of Puppets")
        ]

        let snapshot = LibraryReadSnapshot(tracks: tracks, scannedAt: scannedAt)

        #expect(snapshot.tracks.map(\.id) == ["MK-1"])
        #expect(snapshot.scannedAt == scannedAt)
    }

    @Test("Request normalizes test artists")
    func requestNormalizesTestArtists() {
        let request = LibraryReadRequest(testArtists: [" Metallica ", "", "Radiohead"])

        #expect(request.testArtists == ["Metallica", "Radiohead"])
    }
}
