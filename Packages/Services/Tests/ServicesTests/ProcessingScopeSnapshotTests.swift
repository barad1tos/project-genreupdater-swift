import Core
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
        #expect(snapshot.matchingRule == "artist-or-album-artist-v1")
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
        #expect(snapshot.matchingRule == "artist-or-album-artist-v1")
        #expect(snapshot.fingerprint ==
            "testArtists:aphex twin|boards of canada:rule=artist-or-album-artist-v1:tracks=75")
    }

    @Test("legacy payloads decode without mirror evidence")
    func decodesLegacyEvidence() throws {
        let data = Data(#"""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": -978307100,
          "source": "fullLibrary",
          "normalizedTestArtists": [],
          "matchingRule": "artist-or-album-artist-v1",
          "knownTrackCount": 1,
          "fingerprint": "legacy",
          "reason": "test"
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ProcessingScopeSnapshot.self, from: data)

        #expect(snapshot.mirrorRevision == nil)
        #expect(snapshot.certificateID == nil)
    }

    @Test("current payloads preserve mirror evidence")
    func decodesMirrorEvidence() throws {
        let certificateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        let data = Data(#"""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": -978307100,
          "source": "fullLibrary",
          "normalizedTestArtists": [],
          "matchingRule": "artist-or-album-artist-v1",
          "knownTrackCount": 1,
          "fingerprint": "current",
          "reason": "test",
          "mirrorRevision": {"value": 7},
          "certificateID": "00000000-0000-0000-0000-000000000002"
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ProcessingScopeSnapshot.self, from: data)

        #expect(snapshot.mirrorRevision == MirrorRevision(value: 7))
        #expect(snapshot.certificateID == certificateID)
    }
}
