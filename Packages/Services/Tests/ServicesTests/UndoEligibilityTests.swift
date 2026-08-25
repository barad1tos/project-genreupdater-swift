import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Undo mutation eligibility")
struct UndoEligibilityTests {
    @Test("Revert refuses prerelease AppleScript metadata")
    func revertRefusesPrereleaseStatus() async throws {
        let fixture = try await makeFixture(trackStatus: TrackKind.prerelease.rawValue)

        await #expect(throws: UndoCoordinatorError.self) {
            try await fixture.coordinator.revertChange(fixture.entry)
        }

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.coordinator.getHistory() == [fixture.entry])
    }

    @Test(
        "Revert rejects unknown authoritative status before AppleScript dispatch",
        arguments: [String?.none, "unknown"]
    )
    func revertRejectsUnknownStatus(trackStatus: String?) async throws {
        let fixture = try await makeFixture(trackStatus: trackStatus)

        do {
            try await fixture.coordinator.revertChange(fixture.entry)
            Issue.record("Expected unknown authoritative status to block the revert")
        } catch let error as UndoCoordinatorError {
            guard case let .revertFailed(trackID, reason) = error else {
                Issue.record("Expected revertFailed, got \(error)")
                return
            }
            #expect(trackID == fixture.entry.trackID)
            #expect(reason.contains("not processable"))
            #expect(reason.contains(trackStatus ?? "unknown"))
        }

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        #expect(await fixture.coordinator.getHistory() == [fixture.entry])
    }

    private func makeFixture(trackStatus: String?) async throws -> Fixture {
        let readTrack = Track(
            id: "MK1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2000
        )
        let authoritativeTrack = Track(
            id: "AS1",
            name: readTrack.name,
            artist: readTrack.artist,
            album: readTrack.album,
            year: readTrack.year,
            trackStatus: trackStatus
        )
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: [readTrack],
            appleScriptTracks: [authoritativeTrack]
        )
        let bridge = MusicAppTestAccess()
        await bridge.setFetchedTracks([authoritativeTrack])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: mapper,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("UndoEligibilityTests-\(UUID().uuidString)")
        )
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: readTrack.id,
            artist: readTrack.artist,
            trackName: readTrack.name,
            albumName: readTrack.album
        )
        entry.oldYear = 1998
        entry.newYear = readTrack.year
        try await coordinator.recordChange(entry)
        return Fixture(coordinator: coordinator, bridge: bridge, entry: entry)
    }

    private struct Fixture {
        let coordinator: UndoCoordinator
        let bridge: MusicAppTestAccess
        let entry: ChangeLogEntry
    }
}
