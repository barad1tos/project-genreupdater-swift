import Core
import DesignUI
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
        let (record, item) = uncertainRunRecord(
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

            let blocker = RecoveryObservationBlocker(itemID: item.id, issue: .trackMissing)
            await #expect(throws: AppDependencyServiceError.recoveryItemNeedsAttention(blocker)) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }

            let retained = try #require(await relaunch.store.record(for: record.runID))
            #expect(retained.workItems.first?.recoveryObservationIssue == .trackMissing)
            #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
            #expect(try await setup.changeLog.loadAll().isEmpty)
            #expect(await setup.undo.getHistory().isEmpty)
            #expect(await setup.processor.recoveryHoldID() == recoveryID)
        }
    }

    @Test("Legacy no-op keeps every recovery surface unchanged when Music.app observation throws")
    func failsClosedWhenObservationThrows() async throws {
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
            setup.dependencies.recoveryVerifier = ThrowingRecoveryVerifier()
            let reopened = try #require(await relaunch.store.record(for: record.runID))
            await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

            await #expect(throws: AppDependencyServiceError
                .recoveryObservationNeedsAttention(.observationUnavailable)) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }

            let retained = try #require(await relaunch.store.record(for: record.runID))
            #expect(retained.finishedAt == nil)
            #expect(retained.recoveryID == recoveryID)
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
        let (record, item) = uncertainRunRecord(
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

            let blocker = RecoveryObservationBlocker(itemID: item.id, issue: .trackIdentityChanged)
            let expected = AppDependencyServiceError.recoveryItemNeedsAttention(blocker)
            await #expect(throws: expected) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }

            let expectedGuidance = "Music.app now associates this database ID with a different track; " +
                "open Reports and acknowledge the highlighted item to keep the mirror unchanged"
            #expect(expected.errorDescription == expectedGuidance)
            let retained = try #require(await relaunch.store.record(for: record.runID))
            #expect(retained.workItems.first?.recoveryObservationIssue == .trackIdentityChanged)
            #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
            #expect(await setup.processor.recoveryHoldID() == recoveryID)
        }
    }

    @Test("Legacy no-op identifies the exact item whose Music.app write identity is missing")
    func reportsMissingWriteIdentity() async throws {
        let recoveryID = UUID()
        let item = recoveryWorkItem(
            state: .outcome(.noFixNeeded),
            change: RecoveryWorkChangeFixture(oldValue: nil, newValue: "1970", changeType: .yearUpdate),
            identity: RecoveryTrackIdentityFixture(appleScriptID: nil)
        )
        let record = recoveryRunRecord(recoveryID: recoveryID, workItems: [item])
        let relaunch = try await makeRelaunchedStore(seeding: record)
        defer { try? FileManager.default.removeItem(at: relaunch.directory) }
        let setup = try await makeRecoverySetup(store: relaunch.store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        _ = await setup.processor.beginRecoveryHold(id: recoveryID)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [])
        let reopened = try #require(await relaunch.store.record(for: record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)
        let blocker = RecoveryObservationBlocker(itemID: item.id, issue: .writeIdentityMissing)

        await #expect(throws: AppDependencyServiceError.recoveryItemNeedsAttention(blocker)) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        let retained = try #require(await relaunch.store.record(for: record.runID))
        #expect(retained.workItems.first?.recoveryObservationIssue == .writeIdentityMissing)
        #expect(await setup.processor.recoveryHoldID() == recoveryID)
    }

    @Test("Acknowledging an unobservable legacy no-op clears recovery without changing the mirror")
    func acknowledgesUnobservableLegacyNoOp() async throws {
        var temporaryDirectories: [URL] = []
        defer {
            for temporaryDirectory in temporaryDirectories.reversed() {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }
        let recoveryID = UUID()
        let (record, item) = uncertainRunRecord(
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

            let blocker = RecoveryObservationBlocker(itemID: item.id, issue: .trackMissing)
            await #expect(throws: AppDependencyServiceError.recoveryItemNeedsAttention(blocker)) {
                try await setup.dependencies.clearRecoveryHold(id: recoveryID)
            }
            try await setup.dependencies.dismissRecoveryWork(
                id: record.runID.rawValue,
                itemIDs: [item.id],
                reason: "track removed",
                isIndividual: true
            )

            try await setup.dependencies.clearRecoveryHold(id: recoveryID)

            let closed = try #require(await relaunch.store.record(for: record.runID))
            let acknowledged = try #require(closed.workItems.first)
            #expect(closed.finishedAt != nil)
            #expect(acknowledged.state == .outcome(.noFixNeeded))
            #expect(acknowledged.dismissedAt != nil)
            #expect(acknowledged.detail == "Acknowledged by user; mirror left unchanged: track removed")
            #expect(try await setup.trackStore.getTrack(byID: "persistent-1")?.year == 2001)
            #expect(try await setup.changeLog.loadAll().isEmpty)
            #expect(await setup.undo.getHistory().isEmpty)
            #expect(await setup.processor.recoveryHoldID() == nil)
        }
    }

    @Test("A blocker beyond the report cap identifies only the item that can be acknowledged")
    func exposesCappedMixedBlocker() async throws {
        let recoveryID = UUID()
        let fixture = makeCappedMixedNoOpRecovery(recoveryID: recoveryID)
        let relaunch = try await makeRelaunchedStore(seeding: fixture.record)
        defer { try? FileManager.default.removeItem(at: relaunch.directory) }
        let setup = try await makeRecoverySetup(store: relaunch.store)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        _ = await setup.processor.beginRecoveryHold(id: recoveryID)
        try await setup.trackStore.seedMirror(fixture.mirrorTracks)
        setup.dependencies.installTestAvailability(RecoveryAvailability(checks: RecoveryAvailability.Checks(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )))
        setup.dependencies.recoveryVerifier = RecoveryScriptStub(tracks: [fixture.observedTrack])
        let reopened = try #require(await relaunch.store.record(for: fixture.record.runID))
        await setup.dependencies.runOrchestrator?.restoreRecovery(reopened)

        let blocker = RecoveryObservationBlocker(itemID: fixture.blockedItem.id, issue: .trackMissing)
        await #expect(throws: AppDependencyServiceError.recoveryItemNeedsAttention(blocker)) {
            try await setup.dependencies.clearRecoveryHold(id: recoveryID)
        }

        let retained = try #require(await relaunch.store.record(for: fixture.record.runID))
        let detail = RunReportDetailBuilder.makeDetail(from: retained, now: Date())
        let blockedRow = try #require(detail.workItems.first(where: { $0.id == fixture.blockedItem.id }))
        #expect(!detail.workItems.contains { $0.id == fixture.observedItem.id })
        #expect(blockedRow.canDismiss)
        #expect(blockedRow.attentionLabel == "The track is no longer available in Music.app")
        try assertCappedRecoveryAction(detail: detail, fixture: fixture)

        try await setup.dependencies.dismissRecoveryWork(
            id: fixture.record.runID.rawValue,
            itemIDs: [fixture.blockedItem.id],
            reason: "track removed",
            isIndividual: true
        )
        try await setup.dependencies.clearRecoveryHold(id: recoveryID)

        #expect(try await setup.trackStore.getTrack(byID: "observed-1")?.year == 1969)
        #expect(try await setup.trackStore.getTrack(byID: "missing-1")?.year == 2001)
        #expect(try await setup.changeLog.loadAll().isEmpty)
        #expect(await setup.undo.getHistory().isEmpty)
        #expect(await setup.processor.recoveryHoldID() == nil)
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
            albumArtist: RecoveryAlbumArtistFixture(
                capturedValue: "Artist",
                change: AlbumArtistChange(
                    oldValue: "Artist",
                    newValue: "Renamed Artist"
                )
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

private actor ThrowingRecoveryVerifier: MusicAppVerifying {
    func fetchMetadata(for _: [MusicDatabaseTrackID]) async throws -> [Track] {
        throw RecoveryVerifierError.unavailable
    }
}

private enum RecoveryVerifierError: Error {
    case unavailable
}

private struct CappedMixedNoOpRecovery {
    let record: RunRecord
    let observedItem: RunWorkItem
    let blockedItem: RunWorkItem
    let mirrorTracks: [Track]
    let observedTrack: Track
}

@MainActor
private func assertCappedRecoveryAction(
    detail: RunReportDetailProjection,
    fixture: CappedMixedNoOpRecovery
) throws {
    let snapshot = ReportDetailAdapter.makeSnapshot(from: detail)
    let blockedRow = try #require(
        snapshot.workItems.first(where: { $0.id == fixture.blockedItem.id.uuidString })
    )
    let descriptor = try #require(
        RecoveryItemActionDescriptor.make(detail: snapshot, item: blockedRow)
    )
    #expect(descriptor.attentionLabel == "The track is no longer available in Music.app")
    #expect(descriptor.tone == .warning)
    #expect(descriptor.sectionTitle == "Keep the mirror unchanged")
    #expect(descriptor.accessibilityLabel == "Acknowledge recovery item")
    #expect(descriptor.reasons == ["Track removed", "Identity changed", "Keep mirror unchanged"])
    #expect(descriptor.runID == fixture.record.runID.rawValue.uuidString)
    #expect(descriptor.itemID == fixture.blockedItem.id.uuidString)
    #expect(snapshot.workItems.filter { $0.id != descriptor.itemID }.allSatisfy {
        RecoveryItemActionDescriptor.make(detail: snapshot, item: $0) == nil
    })
    var routedAction: (runID: String, itemID: String, reason: String)?
    descriptor.perform(
        reason: "Track removed",
        using: RecoveryDetailActions(
            applyRemainingFixes: { _ in
                Issue.record("Recovery item action routed to apply remaining fixes")
            },
            dismissItem: { runID, itemID, reason in
                routedAction = (runID, itemID, reason)
            },
            dismissPreparedItems: { _, _, _ in
                Issue.record("Recovery item action routed to dismiss prepared items")
            }
        )
    )
    #expect(routedAction?.runID == fixture.record.runID.rawValue.uuidString)
    #expect(routedAction?.itemID == fixture.blockedItem.id.uuidString)
    #expect(routedAction?.reason == "Track removed")
}

private func makeCappedMixedNoOpRecovery(recoveryID: UUID) -> CappedMixedNoOpRecovery {
    let ordinaryItems = (0 ..< RunReportDetailBuilder.shownWorkItemLimit).map { index in
        recoveryWorkItem(
            state: .outcome(.skipped),
            change: RecoveryWorkChangeFixture(oldValue: nil, newValue: nil),
            identity: RecoveryTrackIdentityFixture(
                readID: "ordinary-read-\(index)",
                appleScriptID: "ordinary-\(index)",
                trackName: "Ordinary \(index)"
            )
        )
    }
    let observedItem = recoveryWorkItem(
        state: .outcome(.noFixNeeded),
        change: RecoveryWorkChangeFixture(oldValue: nil, newValue: "1970", changeType: .yearUpdate),
        identity: RecoveryTrackIdentityFixture(
            readID: "observed-read",
            appleScriptID: "observed-1",
            trackName: "Observed track"
        )
    )
    let blockedItem = recoveryWorkItem(
        state: .outcome(.noFixNeeded),
        change: RecoveryWorkChangeFixture(oldValue: nil, newValue: "1970", changeType: .yearUpdate),
        identity: RecoveryTrackIdentityFixture(
            readID: "missing-read",
            appleScriptID: "missing-1",
            trackName: "Missing track"
        )
    )
    let mirrorTracks = [
        cappedRecoveryTrack(id: "observed-1", name: "Observed track", year: 2001),
        cappedRecoveryTrack(id: "missing-1", name: "Missing track", year: 2001),
    ]
    return CappedMixedNoOpRecovery(
        record: recoveryRunRecord(recoveryID: recoveryID, workItems: ordinaryItems + [observedItem, blockedItem]),
        observedItem: observedItem,
        blockedItem: blockedItem,
        mirrorTracks: mirrorTracks,
        observedTrack: cappedRecoveryTrack(id: "observed-1", name: "Observed track", year: 1969)
    )
}

private func cappedRecoveryTrack(id: String, name: String, year: Int) -> Track {
    Track(
        id: id,
        name: name,
        artist: "Artist",
        album: "Album",
        year: year,
        appleScriptID: id
    )
}
