// ModelContainerFactory.swift — Centralized SwiftData container creation
// Phase 5 Audit Fix: H1 — Single shared ModelContainer for all models

import Core
import CoreData
import Darwin
import Foundation
import SwiftData

/// Creates a shared `ModelContainer` with all SwiftData models.
///
/// Consolidates container creation so that `PersistedTrack` and
/// `PersistedChangeLogEntry` share one container and can maintain
/// relationships.
public enum ModelContainerFactory {
    private static let openCoordinator = StoreOpenCoordinator()

    /// Create a production container persisted to disk.
    public static func create() throws -> ModelContainer {
        let schema = makeSchema()
        let config = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try create(schema: schema, configuration: config)
    }

    /// Create an in-memory container (for testing).
    public static func createInMemory() throws -> ModelContainer {
        let schema = makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try create(schema: schema, configuration: config)
    }

    static func makeSchema() -> Schema {
        Schema(versionedSchema: StoreSchemaV5.self)
    }

    static func create(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        guard !configuration.isStoredInMemoryOnly else {
            return try ModelContainer(for: schema, configurations: [configuration])
        }
        let storeURL = configuration.url.standardizedFileURL.resolvingSymlinksInPath()
        return try openCoordinator.open(at: storeURL) {
            try withStoreLock(at: storeURL) {
                if try needsRecoveryBootstrap(configuration) {
                    try bootstrapRecoveryStore(configuration)
                }
                try prepareLegacyStore(configuration)
                return try ModelContainer(for: schema, configurations: [configuration])
            }
        }
    }

    private static let trackRecoveryChecksum = "i2Q0M3v/JLttbprhy5I8T0nCkA5O9AYoi9OSQRGpY2s="

    private static let legacyVersions = [
        StoreSchemaV0.versionIdentifier,
        StoreSchemaV1.versionIdentifier,
        StoreSchemaV2.versionIdentifier,
        StoreSchemaV3.versionIdentifier,
        StoreSchemaV4.versionIdentifier,
    ].map(\.description)

    private static func withStoreLock<Value>(at storeURL: URL, operation: () throws -> Value) throws -> Value {
        let lockURL = storeURL.appendingPathExtension("migration.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw StoreLockError.openFailed(url: lockURL, code: errno)
        }
        defer { Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            guard code == EINTR else {
                throw StoreLockError.lockFailed(url: lockURL, code: code)
            }
        }
        return try operation()
    }

    private static func prepareLegacyStore(_ configuration: ModelConfiguration) throws {
        guard try isLegacyStore(configuration) else { return }

        let schema = Schema(versionedSchema: StoreSchemaV4.self)
        let legacyConfiguration = ModelConfiguration(
            configuration.name,
            schema: schema,
            url: configuration.url,
            allowsSave: configuration.allowsSave,
            cloudKitDatabase: configuration.cloudKitDatabase
        )
        let container = try ModelContainer(for: schema, configurations: [legacyConfiguration])
        try bootstrapMembership(in: container)
    }

    private static func bootstrapMembership(in container: ModelContainer) throws {
        let context = ModelContext(container)
        guard try context.fetchCount(FetchDescriptor<PersistedLibraryMember>()) == 0 else { return }

        let tracks = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedTrack>())
        let canonicalTracks = tracks.filter { track in
            track.appleScriptID == track.trackID && MusicDatabaseTrackID(rawValue: track.trackID) != nil
        }
        guard !canonicalTracks.isEmpty else { return }

        let revision = try context.fetch(FetchDescriptor<StoreSchemaV2.PersistedMirrorState>())
            .first?
            .revisionValue ?? MirrorRevision.initial.value
        try context.transaction {
            for track in canonicalTracks {
                context.insert(PersistedLibraryMember(
                    databaseID: track.trackID,
                    isPresent: true,
                    firstSeenRevisionValue: revision
                ))
            }
        }
    }

    private static func isLegacyStore(_ configuration: ModelConfiguration) throws -> Bool {
        guard !configuration.isStoredInMemoryOnly else { return false }
        guard FileManager.default.fileExists(atPath: configuration.url.path) else { return false }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: configuration.url
        )
        guard let storedVersions = metadata[NSStoreModelVersionIdentifiersKey] as? [String] else { return false }
        return storedVersions.contains { legacyVersions.contains($0) }
    }

    private static func bootstrapRecoveryStore(_ configuration: ModelConfiguration) throws {
        let schema = Schema(versionedSchema: StoreSchemaV2.self)
        let bootstrapConfiguration = ModelConfiguration(
            configuration.name,
            schema: schema,
            url: configuration.url,
            allowsSave: configuration.allowsSave,
            cloudKitDatabase: configuration.cloudKitDatabase
        )
        _ = try ModelContainer(for: schema, configurations: [bootstrapConfiguration])
    }

    private static func needsRecoveryBootstrap(_ configuration: ModelConfiguration) throws -> Bool {
        guard !configuration.isStoredInMemoryOnly else { return false }
        guard FileManager.default.fileExists(atPath: configuration.url.path) else { return false }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: configuration.url
        )
        return metadata[NSPersistentStoreModelVersionChecksumKey] as? String == trackRecoveryChecksum
    }
}

private final class StoreOpenCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingByURL: [URL: PendingStoreOpen] = [:]

    func open(at storeURL: URL, operation: () throws -> ModelContainer) throws -> ModelContainer {
        let entry: PendingStoreOpen
        let isOwner: Bool
        lock.lock()
        if let pending = pendingByURL[storeURL] {
            entry = pending
            isOwner = false
        } else {
            entry = PendingStoreOpen()
            pendingByURL[storeURL] = entry
            isOwner = true
        }
        lock.unlock()

        guard isOwner else {
            return try entry.wait()
        }

        let result: Result<ModelContainer, any Error>
        do {
            result = try .success(operation())
        } catch {
            result = .failure(error)
        }
        entry.resolve(result)
        lock.withLock {
            if pendingByURL[storeURL] === entry {
                pendingByURL.removeValue(forKey: storeURL)
            }
        }
        return try result.get()
    }
}

private final class PendingStoreOpen: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<ModelContainer, any Error>?

    func wait() throws -> ModelContainer {
        condition.lock()
        while result == nil {
            condition.wait()
        }
        guard let result else {
            condition.unlock()
            throw StoreLockError.missingResult
        }
        condition.unlock()
        return try result.get()
    }

    func resolve(_ result: Result<ModelContainer, any Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }
}

private enum StoreLockError: LocalizedError {
    case openFailed(url: URL, code: Int32)
    case lockFailed(url: URL, code: Int32)
    case missingResult

    var errorDescription: String? {
        switch self {
        case let .openFailed(url, code):
            "Failed to open store lock at \(url.path): \(Self.message(for: code))"
        case let .lockFailed(url, code):
            "Failed to acquire store lock at \(url.path): \(Self.message(for: code))"
        case .missingResult:
            "Store open coordination completed without a result."
        }
    }

    private static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}
