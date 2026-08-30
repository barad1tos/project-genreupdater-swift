import Core

/// Infrastructure dependencies used by ``UpdateCoordinator``.
public struct UpdateDependencies {
    public struct Stores {
        let trackStore: any TrackStateStore
        let cache: any CacheService

        public init(
            trackStore: any TrackStateStore,
            cache: any CacheService
        ) {
            self.trackStore = trackStore
            self.cache = cache
        }
    }

    let apiOrchestrator: APIOrchestrator
    let writer: (any MusicAppMutating & MusicAppVerifying)?
    let stores: Stores
    let undoCoordinator: UndoCoordinator
    let idMapper: (any TrackIDMapping)?
    let librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?
    let analytics: (any AnalyticsService)?
    let effectDrain: MirrorEffectDrain?

    public init(
        apiOrchestrator: APIOrchestrator,
        writer: (any MusicAppMutating & MusicAppVerifying)? = nil,
        stores: Stores,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil,
        analytics: (any AnalyticsService)? = nil,
        effectDrain: MirrorEffectDrain? = nil
    ) {
        self.apiOrchestrator = apiOrchestrator
        self.writer = writer
        self.stores = stores
        self.undoCoordinator = undoCoordinator
        self.idMapper = idMapper
        self.librarySnapshotService = librarySnapshotService
        self.pendingVerificationService = pendingVerificationService
        self.analytics = analytics
        self.effectDrain = effectDrain
    }

    public init(
        apiOrchestrator: APIOrchestrator,
        writer: (any MusicAppMutating & MusicAppVerifying)? = nil,
        trackStore: any TrackStateStore,
        cache: any CacheService,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)?,
        pendingVerificationService: (any PendingVerificationService)?,
        analytics: (any AnalyticsService)? = nil,
        effectDrain: MirrorEffectDrain? = nil
    ) {
        self.init(
            apiOrchestrator: apiOrchestrator,
            writer: writer,
            stores: Stores(trackStore: trackStore, cache: cache),
            undoCoordinator: undoCoordinator,
            idMapper: idMapper,
            pendingVerificationService: pendingVerificationService,
            analytics: analytics,
            effectDrain: effectDrain
        )
    }
}
