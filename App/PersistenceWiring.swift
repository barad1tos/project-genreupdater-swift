import Core
import Foundation
import Services
import SwiftData

func makeProcessContainer() throws -> ModelContainer? {
    guard AppProcessMode.current.shouldUsePersistentStorage else {
        return nil
    }
    return try ModelContainerFactory.create()
}

func makeProcessCache(
    configuration: AppConfiguration,
    apiResultTTL: TimeInterval
) throws -> GRDBCacheService {
    let genericTTL = GRDBCacheService.resolvedGenericTTL(configuration: configuration)
    let maxEntries = configuration.runtime.maxGenericEntries
    let cleanupInterval = TimeInterval(configuration.caching.cleanupIntervalSeconds)
    if !AppProcessMode.current.shouldUsePersistentStorage {
        return try GRDBCacheService.createInMemory(
            defaultGenericTTL: genericTTL,
            apiResultTTL: apiResultTTL,
            maxGenericEntries: maxEntries,
            cleanupInterval: cleanupInterval
        )
    }
    return try GRDBCacheService.createDefault(
        defaultGenericTTL: genericTTL,
        apiResultTTL: apiResultTTL,
        maxGenericEntries: maxEntries,
        cleanupInterval: cleanupInterval
    )
}
