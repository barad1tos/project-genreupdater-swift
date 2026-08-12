import Core
import Services

extension AppDependencies {
    static func makeUndoStores(
        changeLogStore: any ChangeLogStore,
        trackStore: any TrackStateStore,
        cache: any CacheService
    ) -> UndoCoordinator.Stores {
        .init(changeLog: changeLogStore, tracks: trackStore, cache: cache)
    }
}
