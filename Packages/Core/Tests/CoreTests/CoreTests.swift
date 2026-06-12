import Testing
@testable import Core

@Suite("Core Package — Phase 1 Smoke Tests")
struct CoreSmokeTests {
    @Test("Track can be created with minimal fields")
    func trackCreation() {
        let track = Track(id: "ABC123", name: "Test Song", artist: "Test Artist", album: "Test Album")
        #expect(track.id == "ABC123")
        #expect(track.name == "Test Song")
        #expect(track.year == nil)
        #expect(!track.hasBeenProcessed)
    }

    @Test("AppConfiguration creates with defaults")
    func configDefaults() {
        let config = AppConfiguration()
        #expect(config.applescript.concurrency == 2)
        #expect(config.yearRetrieval.enabled)
        #expect(config.processing.batchSize == 25)
    }

    @Test("TrackKind normalizes subscription status")
    func trackStatusNormalization() {
        let kind = normalizeTrackStatus("subscription")
        #expect(kind == .subscription)
        #expect(kind?.canEditMetadata == true)
    }

    @Test("TrackKind recognizes AppleScript raw constants")
    func appleScriptConstants() {
        let kind = TrackKind(rawConstant: "«constant ****kSub»")
        #expect(kind == .subscription)
    }

    @Test("YearResult creates with defaults")
    func yearResultDefaults() {
        let result = YearResult()
        #expect(result.year == nil)
        #expect(!result.isDefinitive)
        #expect(result.confidence == 0)
    }
}

// MARK: - Hotfix Tests

@Suite("TrackStatus — nil handling (CRITICAL-3 fix)")
struct TrackStatusNilHandlingTests {
    @Test("nil trackStatus marks track as available")
    func nilStatusIsAvailable() {
        let track = Track(id: "1", name: "Song", artist: "Artist", album: "Album", trackStatus: nil)
        let filtered = filterAvailableTracks([track])
        #expect(filtered.count == 1, "Tracks with nil status must be included")
    }

    @Test("unrecognized trackStatus marks track as available")
    func unrecognizedStatusIsAvailable() {
        let track = Track(id: "2", name: "Song", artist: "Artist", album: "Album", trackStatus: "unknown_status_xyz")
        let filtered = filterAvailableTracks([track])
        #expect(filtered.count == 1, "Tracks with unrecognized status must be included")
    }

    @Test("prerelease tracks are excluded")
    func prereleaseExcluded() {
        let track = Track(id: "3", name: "Song", artist: "Artist", album: "Album", trackStatus: "prerelease")
        let filtered = filterAvailableTracks([track])
        #expect(filtered.isEmpty, "Prerelease tracks must be excluded")
    }

    @Test("subscription tracks are included")
    func subscriptionIncluded() {
        let track = Track(id: "4", name: "Song", artist: "Artist", album: "Album", trackStatus: "subscription")
        let filtered = filterAvailableTracks([track])
        #expect(filtered.count == 1)
    }

    @Test("mixed statuses filter correctly")
    func mixedStatuses() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Y", trackStatus: nil),
            Track(id: "2", name: "B", artist: "X", album: "Y", trackStatus: "subscription"),
            Track(id: "3", name: "C", artist: "X", album: "Y", trackStatus: "prerelease"),
            Track(id: "4", name: "D", artist: "X", album: "Y", trackStatus: "purchased"),
        ]
        let filtered = filterAvailableTracks(tracks)
        #expect(filtered.count == 3, "Only prerelease should be excluded")
        #expect(!filtered.contains { $0.id == "3" })
    }
}
