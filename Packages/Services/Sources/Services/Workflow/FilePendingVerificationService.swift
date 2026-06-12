// FilePendingVerificationService.swift -- Persistent pending year verification queue.

import Core
import CryptoKit
import Foundation
import OSLog

private struct PendingVerificationStore: Codable {
    var entries: [PendingAlbumEntry]
    var lastAutoVerification: Date?
}

private struct ProblematicAlbumReportRow {
    let entry: PendingAlbumEntry
    let totalAttempts: Int
    let firstAttempt: Date
    let lastAttempt: Date
}

public actor FilePendingVerificationService: Core.PendingVerificationService {
    private let storageURL: URL
    private let defaultReportURL: URL
    private let verificationInterval: TimeInterval
    private let autoVerificationInterval: TimeInterval
    private let currentDate: @Sendable () -> Date
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "PendingVerification")

    private var pendingAlbums: [String: PendingAlbumEntry] = [:]
    private var lastAutoVerification: Date?
    private var hasLoaded = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(
        configuration: AppConfiguration,
        baseDirectory: URL? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        let logsDirectory = baseDirectory ?? Self.resolvedURL(path: configuration.paths.logsBaseDirectory)
        self.storageURL = Self.resolvedURL(
            path: configuration.logging.pendingVerificationFile,
            relativeTo: logsDirectory
        )
        self.defaultReportURL = Self.resolvedURL(
            path: configuration.reporting.problematicAlbumsPath,
            relativeTo: logsDirectory
        )
        let verificationDays = max(0, configuration.processing.pendingVerificationIntervalDays)
        let autoVerificationDays = max(0, configuration.pendingVerification.autoVerifyDays)
        self.verificationInterval = TimeInterval(verificationDays) * 86400
        self.autoVerificationInterval = TimeInterval(autoVerificationDays) * 86400
        self.currentDate = currentDate
        self.fileManager = .default
    }

    public init(
        storageURL: URL,
        problematicReportURL: URL,
        verificationIntervalDays: Int = 30,
        autoVerifyDays: Int = 14,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storageURL = storageURL
        self.defaultReportURL = problematicReportURL
        self.verificationInterval = TimeInterval(max(0, verificationIntervalDays)) * 86400
        self.autoVerificationInterval = TimeInterval(max(0, autoVerifyDays)) * 86400
        self.currentDate = currentDate
        self.fileManager = .default
    }

    public func initialize() async throws {
        try loadFromDisk()
    }

    public func markForVerification(
        artist: String,
        album: String,
        reason: String = "no_year_found",
        metadata: [String: String]? = nil,
        recheckDays: Int? = nil
    ) async {
        loadIfNeeded()

        let key = albumKey(artist: artist, album: album)
        let existing = pendingAlbums[key]
        let interval = recheckDays.map { TimeInterval(max(0, $0)) * 86400 } ?? verificationInterval
        var mergedMetadata = existing?.metadata ?? [:]
        if let metadata {
            mergedMetadata.merge(metadata) { _, new in new }
        }
        if let recheckDays {
            mergedMetadata["recheck_days"] = String(max(0, recheckDays))
        }

        pendingAlbums[key] = PendingAlbumEntry(
            id: key,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            reason: reason,
            attemptCount: (existing?.attemptCount ?? 0) + 1,
            lastAttempt: currentDate(),
            recheckInterval: interval,
            metadata: mergedMetadata
        )
        persistAfterMutation()
    }

    public func removeFromPending(artist: String, album: String) async {
        loadIfNeeded()

        let key = albumKey(artist: artist, album: album)
        guard pendingAlbums.removeValue(forKey: key) != nil else { return }
        persistAfterMutation()
    }

    public func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        loadIfNeeded()
        return pendingAlbums[albumKey(artist: artist, album: album)]
    }

    public func getAttemptCount(artist: String, album: String) async -> Int {
        loadIfNeeded()
        return pendingAlbums[albumKey(artist: artist, album: album)]?.attemptCount ?? 0
    }

    public func isVerificationNeeded(artist: String, album: String) async -> Bool {
        loadIfNeeded()

        guard let entry = pendingAlbums[albumKey(artist: artist, album: album)] else {
            return false
        }
        guard entry.recheckInterval > 0 else {
            return true
        }
        return currentDate() >= entry.lastAttempt.addingTimeInterval(entry.recheckInterval)
    }

    public func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        loadIfNeeded()
        return pendingAlbums.values.sorted {
            let artistOrder = $0.artist.localizedCaseInsensitiveCompare($1.artist)
            if artistOrder != .orderedSame {
                return artistOrder == .orderedAscending
            }
            return $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending
        }
    }

    @discardableResult
    public func generateProblematicAlbumsReport(
        minAttempts: Int = 3,
        reportURL: URL? = nil
    ) async throws -> Int {
        loadIfNeeded()

        let threshold = max(1, minAttempts)
        let now = currentDate()
        let rows = pendingAlbums.values.compactMap { entry -> ProblematicAlbumReportRow? in
            let attempts = totalAttempts(for: entry, now: now)
            guard attempts >= threshold else { return nil }
            let interval = max(1, entry.recheckInterval)
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
        loadIfNeeded()

        guard autoVerificationInterval > 0 else { return false }
        guard let lastAutoVerification else { return true }
        return currentDate() >= lastAutoVerification.addingTimeInterval(autoVerificationInterval)
    }

    public func updateVerificationTimestamp() async throws {
        loadIfNeeded()

        lastAutoVerification = currentDate()
        try saveToDisk()
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        do {
            try loadFromDisk()
        } catch {
            pendingAlbums = [:]
            lastAutoVerification = nil
            hasLoaded = true
            log.warning("Failed to load pending verification storage: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadFromDisk() throws {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            pendingAlbums = [:]
            lastAutoVerification = nil
            hasLoaded = true
            return
        }

        let data = try Data(contentsOf: storageURL)
        let envelope: PendingVerificationStore = if let decodedEnvelope = try? decoder.decode(
            PendingVerificationStore.self,
            from: data
        ) {
            decodedEnvelope
        } else {
            try PendingVerificationStore(
                entries: decoder.decode([PendingAlbumEntry].self, from: data),
                lastAutoVerification: nil
            )
        }

        pendingAlbums = [:]
        for entry in envelope.entries {
            pendingAlbums[entry.id] = entry
        }
        lastAutoVerification = envelope.lastAutoVerification
        hasLoaded = true
    }

    private func persistAfterMutation() {
        do {
            try saveToDisk()
        } catch {
            log
                .warning(
                    "Failed to persist pending verification storage: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private func saveToDisk() throws {
        try ensureDirectoryExists(for: storageURL)
        let envelope = PendingVerificationStore(
            entries: Array(pendingAlbums.values).sorted { $0.id < $1.id },
            lastAutoVerification: lastAutoVerification
        )
        let data = try encoder.encode(envelope)
        try data.write(to: storageURL, options: .atomic)
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
        guard entry.recheckInterval > 0 else {
            return max(1, recordedAttempts)
        }

        let elapsedAttempts = max(0, Int(now.timeIntervalSince(entry.lastAttempt) / entry.recheckInterval)) + 1
        return max(recordedAttempts, elapsedAttempts)
    }

    private static func normalizedKeyPart(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expandedPath = path
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
