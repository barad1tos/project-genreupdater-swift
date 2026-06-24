import Foundation
import Testing
@testable import Core
@testable import Services

private func makeBackupTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("UndoCoordinatorBackupCSVTests-\(UUID().uuidString)")
}

@Suite("UndoCoordinator — backup CSV year revert")
struct UndoCoordinatorBackupCSVTests {
    @Test("Parse backup CSV filters artist and album")
    func parseBackupCSVFiltersArtistAndAlbum() throws {
        let csv = """
        id,name,artist,album,year,year_before_mgu,year_set_by_mgu
        T1,"Song, One",Massive Attack,Mezzanine,1998,1997,1999
        T2,Other,Massive Attack,Protection,,1994,1995
        T3,Skip,Other Artist,Mezzanine,2000,,
        """

        let targets = try YearBackupCSVParser.parse(
            csv,
            artist: "massive attack",
            album: "mezzanine"
        )

        #expect(
            targets == [
                YearBackupRevertTarget(
                    trackID: "T1",
                    trackName: "Song, One",
                    albumName: "Mezzanine",
                    year: 1998
                ),
            ]
        )
    }

    @Test("Revert backup CSV writes years and records revert history")
    func revertBackupCSVWritesYearsAndRecordsHistory() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        T1,Angel,Massive Attack,Mezzanine,1998
        ,Teardrop,Massive Attack,Mezzanine,1998
        MISSING,Missing Track,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
            Track(
                id: "T2",
                name: "Teardrop",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2020
            ),
        ]

        let result = try await coordinator.revertYearsFromBackupCSV(
            csv,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: tracks
        )

        #expect(result.parsedCount == 3)
        #expect(result.updatedCount == 2)
        #expect(result.missingCount == 1)

        let written = await bridge.writtenProperties
        #expect(written.count == 2)
        #expect(written[0].trackID == "T1")
        #expect(written[0].property == "year")
        #expect(written[0].value == "1998")
        #expect(written[1].trackID == "T2")
        #expect(written[1].property == "year")
        #expect(written[1].value == "1998")

        let history = await coordinator.getHistory()
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.changeType == .yearRevert })
        #expect(history.contains { $0.trackID == "T1" && $0.oldYear == 2019 && $0.newYear == 1998 })
        #expect(history.contains { $0.trackID == "T2" && $0.oldYear == 2020 && $0.newYear == 1998 })
    }

    @Test("Backup CSV revert refuses missing AppleScript ID mapping")
    func backupCSVRevertRefusesMissingAppleScriptIDMapping() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        MK1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "MK1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]

        do {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: tracks
            )
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first?.contains("AppleScript ID mapping") == true)
                #expect(descriptions.first?.contains("MK1") == false)
                #expect(error.localizedDescription.contains("AppleScript ID mapping"))
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    @Test("Backup CSV write failure description is public-safe")
    func backupCSVWriteFailureDescriptionIsPublicSafe() async {
        let bridge = MockAppleScriptClient()
        await bridge.setCustomWriteError(RawTrackIDWriteError(trackID: "MK1"))
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            directory: makeBackupTempDirectory()
        )
        let csv = """
        id,name,artist,album,year_before_mgu
        MK1,Angel,Massive Attack,Mezzanine,1998
        """
        let tracks = [
            Track(
                id: "MK1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 2019
            ),
        ]

        do {
            _ = try await coordinator.revertYearsFromBackupCSV(
                csv,
                artist: "Massive Attack",
                album: "Mezzanine",
                currentTracks: tracks
            )
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first == "AppleScript write failed")
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }
}
