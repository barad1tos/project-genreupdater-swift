import Core
import Foundation
import Services
import SwiftData

private var isTestProcess: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

func makeProcessContainer() throws -> ModelContainer {
    if isTestProcess {
        return try ModelContainerFactory.createInMemory()
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
    if isTestProcess {
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
