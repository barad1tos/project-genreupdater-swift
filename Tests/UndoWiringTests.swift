import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies undo wiring")
@MainActor
struct UndoWiringTests {
    @Test("Backup restore through production stores updates the app mirror and history")
    func restoreUpdatesStores() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let trackStore = TrackDataStore(modelContainer: container)
        try await trackStore.initialize()
        let changeLogStore = ChangeLogDataStore(modelContainer: container)
        let track = Track(
            id: "T1",
            name: "Angel",
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            appleScriptID: "T1"
        )
        let scriptClient = DashboardStateScriptClient(verifiedTracks: [track])
        try await trackStore.seedMirror([track])
        let coordinator = UndoCoordinator(
            musicApp: scriptClient,
            stores: AppDependencies.makeUndoStores(
                changeLogStore: changeLogStore,
                trackStore: trackStore,
                cache: DashboardStateCacheService()
            ),
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("UndoWiringTests-\(UUID().uuidString)")
        )
        await coordinator.initialize()

        let result = try await coordinator.revertYearsFromBackupCSV(
            """
            id,name,artist,album,year_before_mgu
            T1,Angel,Massive Attack,Mezzanine,1998
            """,
            artist: "Massive Attack",
            album: "Mezzanine",
            currentTracks: [track]
        )

        #expect(result.updatedCount == 1)
        #expect(try await trackStore.getTrack(byID: track.id)?.year == 1998)
        let history = try await changeLogStore.loadAll()
        #expect(history.count == 1)
        #expect(history.first?.oldYear == 2019)
        #expect(history.first?.newYear == 1998)
        #expect(await scriptClient.updatedProperties().count == 1)
    }
}
