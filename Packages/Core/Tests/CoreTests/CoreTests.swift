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
        #expect(config.processing.batchSize == 50)
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
