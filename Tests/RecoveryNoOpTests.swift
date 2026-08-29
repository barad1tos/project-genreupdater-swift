import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Recovery no-op transition")
@MainActor
struct RecoveryNoOpTests {
    @Test("Legacy no-op preflight reports a stopped Music.app")
    func preflightReportsStoppedMusicApp() async throws {
        try await expectPreflightBlocker(
            .musicAppUnavailable,
            isMusicAppRunning: false,
            areScriptsInstalled: true
        )
    }

    @Test("Legacy no-op preflight reports missing scripts")
    func preflightReportsMissingScripts() async throws {
        try await expectPreflightBlocker(
            .scriptsUnavailable,
            isMusicAppRunning: true,
            areScriptsInstalled: false
        )
    }

    @Test("Relaunched legacy no-op repairs the mirror from Music.app, not the stale plan")
    func observesPhysicalYear() async throws {
        var temporaryDirectories: [URL] = []
        defer {
            for temporaryDirectory in temporaryDirectories.reversed() {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        do {
            let relaunch = try await makeRelaunchedStore(seeding: record)
            temporaryDirectories.append(relaunch.directory)
            let setup = try await makeRecoverySetup(store: relaunch.store)
            temporaryDirectories.append(setup.directory)
            _ = await setup.processor.beginRecoveryHold(id: recoveryID)
            try await setup.trackStore.seedMirror([Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                year: 2001,
                appleScriptID: "persistent-1"
            )])
            setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
                isMusicAppRunning: { true },
                areScriptsInstalled: { true }
            )))
            setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [
                Track(
                    id: "persistent-1",
                    name: "Track",
                    artist: "Artist",
                    album: "Album",
                    year: 1969,
                    appleScriptID: "persistent-1"
                ),
            ])
            let reopened = try #require(await relaunch.store.record(for: record.runID))
            #expect(reopened.workItems.first?.writeChange == nil)
            await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

            try await setup.dependencies.clearRecoveryHold(id: recoveryID)

            let mirrored = try #require(try await setup.trackStore.getTrack(byID: "persistent-1"))
            #expect(mirrored.year == 1969)
            #expect(mirrored.yearBeforeMGU == nil)
            #expect(mirrored.yearSetByMGU == nil)
            #expect(try await setup.changeLog.loadAll().isEmpty)
            #expect(await setup.undo.getHistory().isEmpty)
            #expect(await setup.processor.recoveryHoldID() == nil)
        }
    }

    @Test("Legacy no-op keeps recovery held when Music.app cannot provide the track")
    func failsClosedWithoutTrack() async throws {
        var temporaryDirectories: [URL] = []
        defer {
            for temporaryDirectory in temporaryDirectories.reversed() {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        do {
            let relaunch = try await makeRelaunchedStore(seeding: record)
            temporaryDirectories.append(relaunch.directory)
            let setup = try await makeRecoverySetup(store: relaunch.store)
            temporaryDirectories.append(setup.directory)
            _ = await setup.processor.beginRecoveryHold(id: recoveryID)
            try await setup.trackStore.seedMirror([Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                year: 2001,
                appleScriptID: "persistent-1"
            )])
            setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
                isMusicAppRunning: { true },
                areScriptsInstalled: { true }
            )))
            setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [])
            let reopened = try #require(await relaunch.store.record(for: record.runID))
            await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

            await #expect(throws: AppDependencyServiceError.recoveryObservationNeedsAttention(.trackMissing)) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }

            #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
            #expect(try await setup.changeLog.loadAll().isEmpty)
            #expect(await setup.undo.getHistory().isEmpty)
            #expect(await setup.processor.recoveryHoldID() == recoveryID)
        }
    }

    @Test("Legacy no-op reports a reused Music database identity")
    func reportsChangedTrackIdentity() async throws {
        var temporaryDirectories: [URL] = []
        defer {
            for temporaryDirectory in temporaryDirectories.reversed() {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        do {
            let relaunch = try await makeRelaunchedStore(seeding: record)
            temporaryDirectories.append(relaunch.directory)
            let setup = try await makeRecoverySetup(store: relaunch.store)
            temporaryDirectories.append(setup.directory)
            _ = await setup.processor.beginRecoveryHold(id: recoveryID)
            try await setup.trackStore.seedMirror([Track(
                id: "persistent-1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                year: 2001,
                appleScriptID: "persistent-1"
            )])
            setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
                isMusicAppRunning: { true },
                areScriptsInstalled: { true }
            )))
            setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [
                Track(
                    id: "persistent-1",
                    name: "Different Track",
                    artist: "Different Artist",
                    album: "Different Album",
                    year: 1969,
                    appleScriptID: "persistent-1"
                ),
            ])
            let reopened = try #require(await relaunch.store.record(for: record.runID))
            await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

            let expected = AppDependencyServiceError.recoveryObservationNeedsAttention(.trackIdentityChanged)
            await #expect(throws: expected) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }

            #expect(expected.errorDescription == "Music.app now associates this database ID with a different track")
            #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
            #expect(await setup.processor.recoveryHoldID() == recoveryID)
        }
    }

    @Test("Legacy artist no-op repairs coupled artist fields from Music.app")
    func observesCoupledArtistFields() async throws {
        var temporaryDirectories: [URL] = []
        defer {
            for temporaryDirectory in temporaryDirectories.reversed() {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        let recoveryID = UUID()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: "Artist",
            newValue: "Renamed Artist",
            changeType: .artistRename,
            capturedAlbumArtist: "Artist",
            albumArtistChange: AlbumArtistChange(
                oldValue: "Artist",
                newValue: "Renamed Artist"
            )
        )
        do {
            let relaunch = try await makeRelaunchedStore(seeding: record)
            temporaryDirectories.append(relaunch.directory)
            let setup = try await makeRecoverySetup(store: relaunch.store)
            temporaryDirectories.append(setup.directory)
            _ = await setup.processor.beginRecoveryHold(id: recoveryID)
            try await setup.trackStore.seedMirror([Track(
                id: "persistent-1",
                name: "Track",
                artist: "Stale Artist",
                album: "Album",
                albumArtist: "Stale Album Artist",
                appleScriptID: "persistent-1"
            )])
            setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
                isMusicAppRunning: { true },
                areScriptsInstalled: { true }
            )))
            setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [
                Track(
                    id: "persistent-1",
                    name: "Track",
                    artist: "Artist",
                    album: "Album",
                    albumArtist: "Artist",
                    appleScriptID: "persistent-1"
                ),
            ])
            let reopened = try #require(await relaunch.store.record(for: record.runID))
            #expect(reopened.workItems.first?.writeChange == nil)
            await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

            try await setup.dependencies.clearRecoveryHold(id: recoveryID)

            let mirrored = try #require(try await setup.trackStore.getTrack(byID: "persistent-1"))
            #expect(mirrored.artist == "Artist")
            #expect(mirrored.albumArtist == "Artist")
            #expect(try await setup.changeLog.loadAll().isEmpty)
            #expect(await setup.undo.getHistory().isEmpty)
            #expect(await setup.processor.recoveryHoldID() == nil)
        }
    }

    private func expectPreflightBlocker(
        _ expectedBlocker: RecoveryPreflightBlocker,
        isMusicAppRunning: Bool,
        areScriptsInstalled: Bool
    ) async throws {
        let setup = try await makeRecoverySetup()
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let recoveryID = await setup.processor.beginRecoveryHold()
        let (record, _) = uncertainRunRecord(
            recoveryID: recoveryID,
            itemState: .outcome(.noFixNeeded),
            oldValue: nil,
            newValue: "1970",
            changeType: .yearUpdate
        )
        try await setup.store.upsert(record)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { isMusicAppRunning },
            areScriptsInstalled: { areScriptsInstalled }
        )))

        let outcome = await setup.dependencies.runRecoveryPreflight(runID: record.runID)

        #expect(outcome == .blocked(runID: record.runID, reason: expectedBlocker))
    }
}
