import Core
import Foundation
@testable import Services

struct AcceptedApplyFixture {
    let coordinator: UpdateCoordinator
    let bridge: MusicAppTestAccess
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
    idMapper: (any TrackIDMapping)? = nil,
    analytics: (any AnalyticsService)? = nil
) async -> AcceptedApplyFixture {
    let bridge = MusicAppTestAccess()
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
    let trackStore = MockTrackStore()
    let undo = UndoCoordinator(
        musicApp: bridge,
        stores: .init(tracks: trackStore),
        directory: undoDir
    )
    let coordinator = UpdateCoordinator(
        dependencies: UpdateDependencies(
            apiOrchestrator: orchestrator,
            writer: bridge,
            stores: .init(
                trackStore: trackStore,
                cache: cache
            ),
            undoCoordinator: undo,
            idMapper: idMapper,
            librarySnapshotService: snapshot,
            analytics: analytics
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
        trackStatus: TrackKind.subscription.rawValue,
        appleScriptID: id
    )
}

func acceptedProposals(for track: Track) -> [ProposedChange] {
    [
        ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Stoner Rock",
            confidence: 90,
            source: "Library",
            isAccepted: true
        ),
        ProposedChange(
            track: track,
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        ),
    ]
}

func ignoreAcceptedChangeProgress(_ update: ProgressUpdate) {
    _ = update
}
