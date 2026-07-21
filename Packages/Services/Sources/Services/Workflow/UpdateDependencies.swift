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
    let scriptBridge: any AppleScriptClient
    let stores: Stores
    let undoCoordinator: UndoCoordinator
    let idMapper: (any TrackIDMapping)?
    let librarySnapshotService: (any LibrarySnapshotService)?
    let pendingVerificationService: (any PendingVerificationService)?

    public init(
        apiOrchestrator: APIOrchestrator,
        scriptBridge: any AppleScriptClient,
        stores: Stores,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) {
        self.apiOrchestrator = apiOrchestrator
        self.scriptBridge = scriptBridge
        self.stores = stores
        self.undoCoordinator = undoCoordinator
        self.idMapper = idMapper
        self.librarySnapshotService = librarySnapshotService
        self.pendingVerificationService = pendingVerificationService
    }

    public init(
        apiOrchestrator: APIOrchestrator,
        scriptBridge: any AppleScriptClient,
        trackStore: any TrackStateStore,
        cache: any CacheService,
        undoCoordinator: UndoCoordinator,
        idMapper: (any TrackIDMapping)?,
        pendingVerificationService: (any PendingVerificationService)?
    ) {
        self.init(
            apiOrchestrator: apiOrchestrator,
            scriptBridge: scriptBridge,
            stores: Stores(trackStore: trackStore, cache: cache),
            undoCoordinator: undoCoordinator,
            idMapper: idMapper,
            pendingVerificationService: pendingVerificationService
        )
    }
}
