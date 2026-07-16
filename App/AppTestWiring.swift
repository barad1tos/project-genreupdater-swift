#if DEBUG
import Services

struct TestWriteServices {
    let batchProcessor: BatchProcessor
    let undoCoordinator: UndoCoordinator?
    let updateCoordinator: UpdateCoordinator?
    let mapper: TrackIDMapper?
    let fixPlanStore: (any FixPlanStore)?
    let runRecordStore: (any RunRecordStore)?

    init(
        batchProcessor: BatchProcessor,
        undoCoordinator: UndoCoordinator? = nil,
        updateCoordinator: UpdateCoordinator? = nil,
        mapper: TrackIDMapper? = nil,
        fixPlanStore: (any FixPlanStore)? = nil,
        runRecordStore: (any RunRecordStore)? = nil
    ) {
        self.batchProcessor = batchProcessor
        self.undoCoordinator = undoCoordinator
        self.updateCoordinator = updateCoordinator
        self.mapper = mapper
        self.fixPlanStore = fixPlanStore
        self.runRecordStore = runRecordStore
    }
}

#endif
