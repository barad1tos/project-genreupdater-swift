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

private enum PendingCSVMetadataValue: Decodable {
    case bool(Bool)
    case double(Double)
    case integer(Int)
    case string(String)

    var stringValue: String {
        switch self {
        case let .bool(value):
            value ? "true" : "false"
        case let .double(value):
            String(value)
        case let .integer(value):
            String(value)
        case let .string(value):
            value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }
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

    public func getProblematicPendingAlbums(minAttempts: Int = 3) async -> [ProblematicPendingAlbum] {
        ensureInitialized()

        do {
            return try loadProblematicPendingAlbums(
                minAttempts: minAttempts,
                now: currentDate()
            )
        } catch {
            log.warning("Failed to load problematic pending albums: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    @discardableResult
    public func generateProblematicAlbumsReport(
        minAttempts: Int = 3,
        reportURL: URL? = nil
    ) async throws -> Int {
        ensureInitialized()

        let now = currentDate()
        let rows = try loadProblematicPendingAlbums(minAttempts: minAttempts, now: now)

        let destinationURL = reportURL ?? defaultReportURL
        try ensureDirectoryExists(for: destinationURL)
        let csv = Self.problematicAlbumsCSV(rows: rows)
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
        if let decodedEntries = try? decoder.decode([PendingAlbumEntry].self, from: data) {
            return LegacyPendingVerificationStore(entries: decodedEntries, lastAutoVerification: nil)
        }
        return try decodePythonPendingCSV(data)
    }

    private func decodePythonPendingCSV(_ data: Data) throws -> LegacyPendingVerificationStore {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Pending CSV is not valid UTF-8")
            )
        }

        let rows = Self.parseCSVRows(text)
        guard let header = rows.first else {
            return LegacyPendingVerificationStore(entries: [], lastAutoVerification: nil)
        }

        let columnIndexes = Self.pendingCSVColumnIndexes(header)
        guard Self.hasRequiredPendingCSVColumns(columnIndexes) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Pending CSV header missing expected fields")
            )
        }

        var entries: [PendingAlbumEntry] = []
        for row in rows.dropFirst() {
            if let entry = pendingEntry(fromPendingCSVRow: row, columnIndexes: columnIndexes) {
                entries.append(entry)
            }
        }
        return LegacyPendingVerificationStore(entries: entries, lastAutoVerification: nil)
    }

    private func pendingEntry(
        fromPendingCSVRow row: [String],
        columnIndexes: [String: Int]
    ) -> PendingAlbumEntry? {
        let artist = Self.csvField("artist", in: row, columnIndexes: columnIndexes)
        let album = Self.csvField("album", in: row, columnIndexes: columnIndexes)
        let timestamp = Self.csvField("timestamp", in: row, columnIndexes: columnIndexes)
        guard !artist.isEmpty, !album.isEmpty, let lastAttempt = Self.parsePendingCSVTimestamp(timestamp) else {
            return nil
        }

        let reason = Self.pendingCSVReason(Self.csvField("reason", in: row, columnIndexes: columnIndexes))
        let metadata = Self.pendingCSVMetadata(Self.csvField("metadata", in: row, columnIndexes: columnIndexes))
        let attemptCount = Self.pendingCSVAttemptCount(
            Self.csvField("attempt_count", in: row, columnIndexes: columnIndexes)
        )

        return PendingAlbumEntry(
            id: albumKey(artist: artist, album: album),
            artist: artist,
            album: album,
            reason: reason,
            attemptCount: attemptCount,
            lastAttempt: lastAttempt,
            recheckInterval: pendingCSVRecheckInterval(reason: reason, metadata: metadata),
            metadata: metadata
        )
    }

    private func pendingCSVRecheckInterval(reason: String, metadata: [String: String]) -> TimeInterval {
        if let recheckDays = Self.positiveRecheckDays(metadata["recheck_days"]) {
            return TimeInterval(recheckDays) * 86400
        }
        if Self.isPrereleaseReason(reason) {
            return TimeInterval(prereleaseRecheckDays) * 86400
        }
        return verificationInterval
    }

    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let nextCharacter = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "\"" {
                if isQuoted, nextCharacter == "\"" {
                    field.append(character)
                    index += 1
                } else {
                    isQuoted.toggle()
                }
            } else if character == ",", !isQuoted {
                row.append(field)
                field.removeAll(keepingCapacity: true)
            } else if character == "\n" || character == "\r", !isQuoted {
                row.append(field)
                field.removeAll(keepingCapacity: true)
                if row.contains(where: { !$0.isEmpty }) {
                    rows.append(row)
                }
                row.removeAll(keepingCapacity: true)
                if character == "\r", nextCharacter == "\n" {
                    index += 1
                }
            } else {
                field.append(character)
            }

            index += 1
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func pendingCSVColumnIndexes(_ header: [String]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, field) in header.enumerated() {
            indexes[field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = index
        }
        return indexes
    }

    private static func hasRequiredPendingCSVColumns(_ columnIndexes: [String: Int]) -> Bool {
        columnIndexes["artist"] != nil
            && columnIndexes["album"] != nil
            && columnIndexes["timestamp"] != nil
    }

    private static func csvField(
        _ name: String,
        in row: [String],
        columnIndexes: [String: Int]
    ) -> String {
        guard let index = columnIndexes[name], row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pendingCSVReason(_ value: String) -> String {
        let normalizedReason = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard pendingCSVKnownReasons.contains(normalizedReason) else { return "no_year_found" }
        return normalizedReason
    }

    private static let pendingCSVKnownReasons: Set<String> = [
        "absurd_year_no_existing",
        "implausible_existing_year",
        "implausible_matching_year",
        "implausible_proposed_year",
        "no_year_found",
        "prerelease",
        "special_album_compilation",
        "special_album_reissue",
        "special_album_special",
        "suspicious_album_name",
        "suspicious_year_change",
        "very_low_confidence_no_existing",
    ]

    private static func parsePendingCSVTimestamp(_ value: String) -> Date? {
        pendingCSVDateFormatter(format: "yyyy-MM-dd HH:mm:ss").date(from: value)
            ?? pendingCSVDateFormatter(format: "yyyy-MM-dd").date(from: value)
    }

    private static func pendingCSVDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private static func pendingCSVMetadata(_ value: String) -> [String: String] {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return [:] }
        guard let values = try? JSONDecoder().decode([String: PendingCSVMetadataValue].self, from: data) else {
            return [:]
        }
        return values.mapValues(\.stringValue)
    }

    private static func pendingCSVAttemptCount(_ value: String) -> Int {
        guard let count = Int(value), count > 0 else { return 0 }
        return count
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

    private func loadProblematicPendingAlbums(
        minAttempts: Int,
        now: Date
    ) throws -> [ProblematicPendingAlbum] {
        let descriptor = FetchDescriptor<PersistedPendingAlbumEntry>()
        let entries = try modelContext.fetch(descriptor).map { $0.toPendingAlbumEntry() }
        let threshold = max(1, minAttempts)

        return entries.compactMap { entry -> ProblematicPendingAlbum? in
            let attempts = totalAttempts(for: entry, now: now)
            guard attempts >= threshold else { return nil }
            let interval = max(1, effectiveRecheckInterval(for: entry))
            let firstAttempt = entry.lastAttempt.addingTimeInterval(-Double(max(0, attempts - 1)) * interval)

            return ProblematicPendingAlbum(
                entry: entry,
                totalAttempts: attempts,
                firstAttempt: firstAttempt,
                lastAttempt: entry.lastAttempt,
                daysSinceFirstAttempt: Self.daysElapsed(from: firstAttempt, to: now)
            )
        }.sorted {
            if $0.totalAttempts != $1.totalAttempts {
                return $0.totalAttempts > $1.totalAttempts
            }
            return $0.entry.album.localizedCaseInsensitiveCompare($1.entry.album) == .orderedAscending
        }
    }

    private static func daysElapsed(from startDate: Date, to endDate: Date) -> Int {
        max(0, Int(endDate.timeIntervalSince(startDate) / 86400))
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

    private static func problematicAlbumsCSV(rows: [ProblematicPendingAlbum]) -> String {
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
                String(row.daysSinceFirstAttempt),
                row.status,
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
