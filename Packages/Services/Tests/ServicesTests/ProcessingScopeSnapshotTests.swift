import Foundation
import Services
import Testing

@Suite("ProcessingScopeSnapshot")
struct ProcessingScopeSnapshotTests {
    @Test("captures full library when no test artists are configured")
    func capturesFullLibraryScope() {
        let snapshot = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [" ", "\n"],
            knownTrackCount: 35224,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "manual-check"
        )

        #expect(snapshot.source == .fullLibrary)
        #expect(snapshot.normalizedTestArtists.isEmpty)
        #expect(snapshot.knownTrackCount == 35224)
        #expect(snapshot.fingerprint == "fullLibrary::tracks=35224")
    }

    @Test("deduplicates test artists with canonical allow-list normalization")
    func deduplicatesTestArtists() {
        let snapshot = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [" Aphex Twin ", "aphex twin", "Boards of Canada"],
            knownTrackCount: 75,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "manual-check"
        )

        #expect(snapshot.source == .testArtists)
        #expect(snapshot.normalizedTestArtists == ["Aphex Twin", "Boards of Canada"])
        #expect(snapshot.fingerprint == "testArtists:aphex twin|boards of canada:tracks=75")
    }
}
