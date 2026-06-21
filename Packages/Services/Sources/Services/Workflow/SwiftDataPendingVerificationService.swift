// SwiftDataPendingVerificationService.swift -- SwiftData-backed pending year verification queue.

import Core
import CryptoKit
import Foundation
import OSLog
import SwiftData

private struct LegacyPendingVerificationStore: Codable {
    var entries: [PendingAlbumEntry]
    var lastAutoVerification: Date?
}

private struct ProblematicAlbumReportRow {
    let entry: PendingAlbumEntry
    let totalAttempts: Int
    let firstAttempt: Date
    let lastAttempt: Date
}

/// Stores pending album verification state in SwiftData.
///
/// The legacy JSON path is only read as a migration source. New runtime state
/// is persisted through the shared SwiftData container.
public actor SwiftDataPendingVerificationService: ModelActor, Core.PendingVerificationService {
    nonisolated public let modelExecutor: any ModelExecutor
    nonisolated public let modelContainer: ModelContainer

    private let legacyStorageURL: URL?
    private let defaultReportURL: URL
    private let verificationInterval: TimeInterval
    private let prereleaseRecheckDays: Int
    private let autoVerificationInterval: TimeInterval
    private let currentDate: @Sendable () -> Date
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "PendingVerification")

    private var hasInitialized = false

    public init(
        modelContainer: ModelContainer,
        configuration: AppConfiguration,
        baseDirectory: URL? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer

        let logsDirectory = baseDirectory ?? Self.resolvedURL(path: configuration.paths.effectiveLogsBaseDirectory)
        self.legacyStorageURL = Self.resolvedURL(
            path: configuration.logging.pendingVerificationFile,
            relativeTo: logsDirectory
        )
        self.defaultReportURL = Self.resolvedURL(
            path: configuration.reporting.problematicAlbumsPath,
            relativeTo: logsDirectory
        )
        let verificationDays = max(0, configuration.processing.pendingVerificationIntervalDays)
        let prereleaseRecheckDays = Self.resolvedPrereleaseRecheckDays(
            configuration.processing.prereleaseRecheckDays,
            fallbackDays: verificationDays
        )
        let autoVerificationDays = max(0, configuration.pendingVerification.autoVerifyDays)
        self.verificationInterval = TimeInterval(verificationDays) * 86400
        self.prereleaseRecheckDays = prereleaseRecheckDays
        self.autoVerificationInterval = TimeInterval(autoVerificationDays) * 86400
        self.currentDate = currentDate
        self.fileManager = .default
    }

    public init(
        modelContainer: ModelContainer,
        legacyStorageURL: URL? = nil,
        problematicReportURL: URL,
        verificationIntervalDays: Int = 30,
        prereleaseRecheckDays: Int? = nil,
        autoVerifyDays: Int = 14,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        let modelContext = ModelContext(modelContainer)
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.modelContainer = modelContainer

        self.legacyStorageURL = legacyStorageURL
        self.defaultReportURL = problematicReportURL
        let verificationDays = max(0, verificationIntervalDays)
        self.verificationInterval = TimeInterval(verificationDays) * 86400
        self.prereleaseRecheckDays = Self.resolvedPrereleaseRecheckDays(
            prereleaseRecheckDays ?? verificationDays,
            fallbackDays: verificationDays
        )
        self.autoVerificationInterval = TimeInterval(max(0, autoVerifyDays)) * 86400
        self.currentDate = currentDate
        self.fileManager = .default
    }

    public func initialize() async throws {
        try migrateLegacyStoreIfNeeded()
        hasInitialized = true
    }

    public func markForVerification(
        artist: String,
        album: String,
        reason: String = "no_year_found",
        metadata: [String: String]? = nil,
        recheckDays: Int? = nil
    ) async {
        ensureInitialized()

        let key = albumKey(artist: artist, album: album)
        let existing = (try? fetchEntry(id: key))?.toPendingAlbumEntry()
        let resolvedRecheckDays = resolvedRecheckDays(reason: reason, recheckDays: recheckDays)
        let interval = resolvedRecheckDays.map { TimeInterval($0) * 86400 } ?? verificationInterval
        var mergedMetadata = existing?.metadata ?? [:]
        if let metadata {
            mergedMetadata.merge(metadata) { _, new in new }
        }
        if let resolvedRecheckDays {
            mergedMetadata["recheck_days"] = String(resolvedRecheckDays)
        }

        let entry = PendingAlbumEntry(
            id: key,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: reason,
            attemptCount: (existing?.attemptCount ?? 0) + 1,
            lastAttempt: currentDate(),
            recheckInterval: interval,
            metadata: mergedMetadata
        )

        do {
            try upsert(entry)
            try modelContext.save()
        } catch {
            log.warning("Failed to persist pending verification entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func removeFromPending(artist: String, album: String) async {
        ensureInitialized()

        do {
            guard let entry = try fetchEntry(id: albumKey(artist: artist, album: album)) else { return }
            modelContext.delete(entry)
            try modelContext.save()
        } catch {
            log.warning("Failed to remove pending verification entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        ensureInitialized()
        return (try? fetchEntry(id: albumKey(artist: artist, album: album)))?.toPendingAlbumEntry()
    }

    public func getAttemptCount(artist: String, album: String) async -> Int {
        ensureInitialized()
        return (try? fetchEntry(id: albumKey(artist: artist, album: album)))?.attemptCount ?? 0
    }

    public func isVerificationNeeded(artist: String, album: String) async -> Bool {
        ensureInitialized()

        guard let entry = (try? fetchEntry(id: albumKey(artist: artist, album: album)))?.toPendingAlbumEntry() else {
            return false
        }
        let recheckInterval = effectiveRecheckInterval(for: entry)
        guard recheckInterval > 0 else {
            return true
        }
        return currentDate() >= entry.lastAttempt.addingTimeInterval(recheckInterval)
    }

    public func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        ensureInitialized()

        do {
            let descriptor = FetchDescriptor<PersistedPendingAlbumEntry>(
                sortBy: [
                    SortDescriptor(\.artist),
                    SortDescriptor(\.album),
                ]
            )
            return try modelContext.fetch(descriptor).map { $0.toPendingAlbumEntry() }
        } catch {
            log.warning("Failed to load pending verification entries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    @discardableResult
    public func generateProblematicAlbumsReport(
        minAttempts: Int = 3,
        reportURL: URL? = nil
    ) async throws -> Int {
        ensureInitialized()

        let descriptor = FetchDescriptor<PersistedPendingAlbumEntry>()
        let entries = try modelContext.fetch(descriptor).map { $0.toPendingAlbumEntry() }
        let threshold = max(1, minAttempts)
        let now = currentDate()
        let rows = entries.compactMap { entry -> ProblematicAlbumReportRow? in
            let attempts = totalAttempts(for: entry, now: now)
            guard attempts >= threshold else { return nil }
            let interval = max(1, effectiveRecheckInterval(for: entry))
            let firstAttempt = entry.lastAttempt.addingTimeInterval(-Double(max(0, attempts - 1)) * interval)
            return ProblematicAlbumReportRow(
                entry: entry,
                totalAttempts: attempts,
                firstAttempt: firstAttempt,
                lastAttempt: entry.lastAttempt
            )
        }.sorted {
            if $0.totalAttempts != $1.totalAttempts {
                return $0.totalAttempts > $1.totalAttempts
            }
            return $0.entry.album.localizedCaseInsensitiveCompare($1.entry.album) == .orderedAscending
        }

        let destinationURL = reportURL ?? defaultReportURL
        try ensureDirectoryExists(for: destinationURL)
        let csv = Self.problematicAlbumsCSV(rows: rows, now: now)
        try Data(csv.utf8).write(to: destinationURL, options: .atomic)
        return rows.count
    }

    public func shouldAutoVerify() async -> Bool {
        ensureInitialized()

        guard autoVerificationInterval > 0 else { return false }
        guard let lastAutoVerification = (try? fetchMetadata())?.lastAutoVerification else {
            return true
        }
        return currentDate() >= lastAutoVerification.addingTimeInterval(autoVerificationInterval)
    }

    public func updateVerificationTimestamp() async throws {
        ensureInitialized()

        let metadata = try getOrCreateMetadata()
        metadata.lastAutoVerification = currentDate()
        try modelContext.save()
    }
}

extension SwiftDataPendingVerificationService {
    private func ensureInitialized() {
        guard !hasInitialized else { return }
        do {
            try migrateLegacyStoreIfNeeded()
        } catch {
            log
                .warning(
                    "Failed to migrate pending verification storage: \(error.localizedDescription, privacy: .public)"
                )
        }
        hasInitialized = true
    }

    private func migrateLegacyStoreIfNeeded() throws {
        guard let legacyStorageURL else { return }

        let existingEntries = try modelContext.fetchCount(FetchDescriptor<PersistedPendingAlbumEntry>())
        let existingMetadata = try fetchMetadata()
        guard existingEntries == 0, existingMetadata?.lastAutoVerification == nil else {
            return
        }
        guard fileManager.fileExists(atPath: legacyStorageURL.path) else {
            return
        }

        let envelope = try decodeLegacyStore(from: legacyStorageURL)
        for entry in envelope.entries {
            try upsert(normalizedEntry(entry))
        }

        if let lastAutoVerification = envelope.lastAutoVerification {
            let metadata = try getOrCreateMetadata()
            metadata.lastAutoVerification = lastAutoVerification
        }

        try modelContext.save()
        log.info("Migrated \(envelope.entries.count, privacy: .public) pending verification entrie(s) to SwiftData")
    }

    private func decodeLegacyStore(from url: URL) throws -> LegacyPendingVerificationStore {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decodedEnvelope = try? decoder.decode(LegacyPendingVerificationStore.self, from: data) {
            return decodedEnvelope
        }
        return try LegacyPendingVerificationStore(
            entries: decoder.decode([PendingAlbumEntry].self, from: data),
            lastAutoVerification: nil
        )
    }

    private func fetchEntry(id: String) throws -> PersistedPendingAlbumEntry? {
        let descriptor = FetchDescriptor<PersistedPendingAlbumEntry>(
            predicate: #Predicate { $0.entryID == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchMetadata() throws -> PersistedPendingVerificationMetadata? {
        let descriptor = FetchDescriptor<PersistedPendingVerificationMetadata>()
        return try modelContext.fetch(descriptor).first
    }

    private func getOrCreateMetadata() throws -> PersistedPendingVerificationMetadata {
        if let existing = try fetchMetadata() {
            return existing
        }
        let metadata = PersistedPendingVerificationMetadata()
        modelContext.insert(metadata)
        return metadata
    }

    private func upsert(_ entry: PendingAlbumEntry) throws {
        if let existing = try fetchEntry(id: entry.id) {
            existing.update(from: entry)
        } else {
            modelContext.insert(PersistedPendingAlbumEntry(from: entry))
        }
    }

    private func normalizedEntry(_ entry: PendingAlbumEntry) -> PendingAlbumEntry {
        PendingAlbumEntry(
            id: albumKey(artist: entry.artist, album: entry.album),
            artist: entry.artist,
            album: entry.album,
            reason: entry.reason,
            attemptCount: entry.attemptCount,
            lastAttempt: entry.lastAttempt,
            recheckInterval: entry.recheckInterval,
            metadata: entry.metadata
        )
    }

    private func ensureDirectoryExists(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func albumKey(artist: String, album: String) -> String {
        let rawKey = "\(Self.normalizedKeyPart(artist))|\(Self.normalizedKeyPart(album))"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func totalAttempts(for entry: PendingAlbumEntry, now: Date) -> Int {
        let recordedAttempts = max(0, entry.attemptCount)
        let recheckInterval = effectiveRecheckInterval(for: entry)
        guard recheckInterval > 0 else {
            return max(1, recordedAttempts)
        }

        let elapsedAttempts = max(0, Int(now.timeIntervalSince(entry.lastAttempt) / recheckInterval)) + 1
        return max(recordedAttempts, elapsedAttempts)
    }

    private func resolvedRecheckDays(reason: String, recheckDays: Int?) -> Int? {
        if let recheckDays = Self.positiveRecheckDays(recheckDays) {
            return recheckDays
        }
        guard Self.isPrereleaseReason(reason) else { return nil }
        return prereleaseRecheckDays
    }

    private static func resolvedPrereleaseRecheckDays(_ days: Int, fallbackDays: Int) -> Int {
        let normalizedDays = max(0, days)
        guard normalizedDays > 0 else { return fallbackDays }
        return normalizedDays
    }

    private static func isPrereleaseReason(_ reason: String) -> Bool {
        let normalizedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalizedReason == "prerelease" || normalizedReason == "pre_release"
    }

    private func effectiveRecheckInterval(for entry: PendingAlbumEntry) -> TimeInterval {
        guard Self.isPrereleaseReason(entry.reason) else {
            return entry.recheckInterval
        }
        let recheckDays = Self.positiveRecheckDays(entry.metadata["recheck_days"]) ?? prereleaseRecheckDays
        return TimeInterval(recheckDays) * 86400
    }

    private static func positiveRecheckDays(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positiveRecheckDays(_ value: String?) -> Int? {
        guard let value else { return nil }
        return positiveRecheckDays(Int(value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func normalizedKeyPart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = defaultDirectory().path
        var expandedPath = path
            .replacingOccurrences(of: "${APP_SUPPORT}", with: appSupport)
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
        if expandedPath == "~" {
            expandedPath = home
        } else if expandedPath.hasPrefix("~/") {
            expandedPath = home + String(expandedPath.dropFirst())
        }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return (baseURL ?? defaultDirectory()).appendingPathComponent(expandedPath)
    }

    private static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }

    private static func problematicAlbumsCSV(rows: [ProblematicAlbumReportRow], now: Date) -> String {
        var lines = [
            "Artist,Album,First Attempt,Last Attempt,Total Attempts,Days Since First Attempt,Status",
        ]
        lines.append(contentsOf: rows.map { row in
            [
                row.entry.artist,
                row.entry.album,
                dateOnly(row.firstAttempt),
                dateOnly(row.lastAttempt),
                String(row.totalAttempts),
                String(max(0, Calendar.current.dateComponents([.day], from: row.firstAttempt, to: now).day ?? 0)),
                "Pending verification",
            ].map(escapeCSVField).joined(separator: ",")
        })
        return lines.joined(separator: "\r\n")
    }

    private static func dateOnly(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    private static func escapeCSVField(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")

        guard needsQuoting else { return value }

        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
