import Core
import Foundation
@testable import Services

struct AcceptedApplyFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
    let cache: MockCacheService
    let snapshot: MockLibrarySnapshotService
    let trackStore: MockTrackStore
    let undo: UndoCoordinator
}

actor CheckpointProbe {
    private(set) var values: [WorkCheckpoint] = []
    private(set) var verifiedEffects: [CheckpointEffects] = []

    func append(_ checkpoint: WorkCheckpoint, effects: CheckpointEffects? = nil) {
        values.append(checkpoint)
        if let effects {
            verifiedEffects.append(effects)
        }
    }
}

struct CheckpointEffects: Sendable {
    let historyCount: Int
    let mirrorCount: Int
}

func makeCoordinator(
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
    idMapper: (any TrackIDMapping)? = nil
) async -> AcceptedApplyFixture {
    let bridge = MockAppleScriptClient()
    let apiService = MockAPIService()
    let orchestrator = makeAPIOrchestrator(
        musicBrainz: apiService,
        discogs: apiService,
        appleMusic: apiService
    )
    let undoDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplyAcceptedTests-\(UUID().uuidString)")
    let cache = MockCacheService()
    let snapshot = MockLibrarySnapshotService()
    let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
    let trackStore = MockTrackStore()
    let coordinator = UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            stores: .init(
                trackStore: trackStore,
                cache: cache
            ),
            undoCoordinator: undo,
            idMapper: idMapper,
            librarySnapshotService: snapshot
        ),
        genreDeterminator: GenreDeterminator(),
        yearDeterminator: YearDeterminator(),
        runtimeConfiguration: runtimeConfiguration
    )

    return AcceptedApplyFixture(
        coordinator: coordinator,
        bridge: bridge,
        cache: cache,
        snapshot: snapshot,
        trackStore: trackStore,
        undo: undo
    )
}

func makeEditableTrack(
    id: String,
    genre: String?,
    year: Int?,
    album: String = "Abbey Road"
) -> Track {
    Track(
        id: id,
        name: "Come Together",
        artist: "Beatles",
        album: album,
        genre: genre,
        year: year,
        trackStatus: TrackKind.subscription.rawValue
    )
}

func ignoreAcceptedChangeProgress(_ update: ProgressUpdate) {
    _ = update
}
