import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

private struct LegacyPendingVerificationTestStore: Codable {
    var entries: [PendingAlbumEntry]
    var lastAutoVerification: Date?
}

@Suite("SwiftDataPendingVerificationService - persistent pending albums")
struct SwiftDataPendingVerificationServiceTests {
    private let day: TimeInterval = 86400

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeService(
        container: ModelContainer,
        directory: URL,
        date: Date,
        verificationIntervalDays: Int = 30,
        autoVerifyDays: Int = 14,
        legacyStorageURL: URL? = nil
    ) -> SwiftDataPendingVerificationService {
        SwiftDataPendingVerificationService(
            modelContainer: container,
            legacyStorageURL: legacyStorageURL,
            problematicReportURL: directory.appendingPathComponent("problematic.csv"),
            verificationIntervalDays: verificationIntervalDays,
            autoVerifyDays: autoVerifyDays,
            currentDate: { date }
        )
    }

    @Test("Marking an album persists attempts, metadata, and recheck interval in SwiftData")
    func markForVerificationPersistsAndIncrementsAttempts() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(
            container: container,
            directory: directory,
            date: baseDate,
            verificationIntervalDays: 30
        )
        await service.markForVerification(
            artist: "  Massive Attack  ",
            album: "  Mezzanine  ",
            reason: "missing_year",
            metadata: ["source": "musicbrainz"]
        )
        await service.markForVerification(
            artist: "Massive Attack",
            album: "Mezzanine",
            reason: "low_confidence",
            metadata: ["confidence": "45"],
            recheckDays: 7
        )

        let entry = try #require(await service.getEntry(artist: "Massive Attack", album: "Mezzanine"))
        #expect(entry.artist == "Massive Attack")
        #expect(entry.album == "Mezzanine")
        #expect(entry.reason == "low_confidence")
        #expect(entry.attemptCount == 2)
        #expect(entry.recheckInterval == 7 * day)
        #expect(entry.metadata["source"] == "musicbrainz")
        #expect(entry.metadata["confidence"] == "45")
        #expect(entry.metadata["recheck_days"] == "7")
        #expect(await service.getAttemptCount(artist: "Massive Attack", album: "Mezzanine") == 2)
        #expect(await !(service.isVerificationNeeded(artist: "Massive Attack", album: "Mezzanine")))

        let reloaded = makeService(
            container: container,
            directory: directory,
            date: baseDate.addingTimeInterval(8 * day),
            verificationIntervalDays: 30
        )
        let persisted = try #require(await reloaded.getEntry(artist: "Massive Attack", album: "Mezzanine"))
        #expect(persisted.attemptCount == 2)
        #expect(persisted.metadata["source"] == "musicbrainz")
        #expect(await reloaded.isVerificationNeeded(artist: "Massive Attack", album: "Mezzanine"))
    }

    @Test("Pending albums can be filtered by normalized reason")
    func pendingAlbumsCanBeFilteredByReason() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(container: container, directory: directory, date: baseDate)
        await service.markForVerification(artist: "Portishead", album: "Dummy", reason: "missing_year")
        await service.markForVerification(artist: "Slowdive", album: "Everything Is Alive", reason: " PRERELEASE ")
        await service.markForVerification(
            artist: "Low",
            album: "HEY WHAT",
            reason: "stale_api_data_for_fresh_album"
        )

        let missingYearEntries = await service.getPendingAlbums(reason: "missing-year")
        let prereleaseEntries = await service.getPendingAlbums(reason: "pre-release")
        let staleAPIEntries = await service.getPendingAlbums(reason: "STALE_API_DATA_FOR_FRESH_ALBUM")

        #expect(missingYearEntries.map(\.album) == ["Dummy"])
        #expect(prereleaseEntries.map(\.album) == ["Everything Is Alive"])
        #expect(staleAPIEntries.map(\.album) == ["HEY WHAT"])
    }

    @Test("Prerelease entries use the configured prerelease recheck interval")
    func prereleaseEntriesUseConfiguredRecheckInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = AppConfiguration()
        configuration.processing.pendingVerificationIntervalDays = 30
        configuration.processing.prereleaseRecheckDays = 7

        let service = SwiftDataPendingVerificationService(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate }
        )
        await service.markForVerification(artist: "Slowdive", album: "Everything Is Alive", reason: "prerelease")

        let entry = try #require(await service.getEntry(artist: "Slowdive", album: "Everything Is Alive"))
        #expect(entry.recheckInterval == 7 * day)
        #expect(entry.metadata["recheck_days"] == "7")

        let beforeRecheck = SwiftDataPendingVerificationService(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate.addingTimeInterval(6 * day) }
        )
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive")))

        let afterRecheck = SwiftDataPendingVerificationService(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate.addingTimeInterval(7 * day) }
        )
        #expect(await afterRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive"))
    }

    @Test("Due pending albums use each entry's effective recheck interval")
    func duePendingAlbumsUseEffectiveRecheckInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var configuration = AppConfiguration()
        configuration.processing.pendingVerificationIntervalDays = 30
        configuration.processing.prereleaseRecheckDays = 7

        let initial = SwiftDataPendingVerificationService(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate }
        )
        await initial.markForVerification(artist: "Portishead", album: "Dummy", reason: "no_year_found")
        await initial.markForVerification(artist: "Slowdive", album: "Everything Is Alive", reason: "prerelease")

        let afterPrereleaseInterval = SwiftDataPendingVerificationService(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate.addingTimeInterval(7 * day) }
        )

        let dueEntries = await afterPrereleaseInterval.getDuePendingAlbums()
        let snapshot = await afterPrereleaseInterval.getPendingVerificationSnapshot()

        #expect(dueEntries.map(\.album) == ["Everything Is Alive"])
        #expect(snapshot.all.map(\.album).sorted() == ["Dummy", "Everything Is Alive"])
        #expect(snapshot.due.map(\.album) == ["Everything Is Alive"])
    }

    @Test("Imported prerelease entries without recheck metadata use the configured prerelease interval")
    func importedPrereleaseEntriesWithoutMetadataUseConfiguredRecheckInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = PendingAlbumEntry(
            id: "legacy-prerelease",
            artist: "Slowdive",
            album: "Everything Is Alive",
            reason: "prerelease",
            attemptCount: 1,
            lastAttempt: baseDate,
            recheckInterval: 30 * day
        )
        let envelope = LegacyPendingVerificationTestStore(entries: [entry], lastAutoVerification: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let beforeRecheck = SwiftDataPendingVerificationService(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            problematicReportURL: directory.appendingPathComponent("problematic.csv"),
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate.addingTimeInterval(6 * day) }
        )
        try await beforeRecheck.initialize()
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive")))

        let afterRecheck = SwiftDataPendingVerificationService(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            problematicReportURL: directory.appendingPathComponent("problematic.csv"),
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate.addingTimeInterval(7 * day) }
        )
        #expect(await afterRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive"))
    }

    @Test("Marking an album does not create a pending JSON file")
    func markForVerificationDoesNotCreateJSONStore() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")

        let service = makeService(
            container: container,
            directory: directory,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            legacyStorageURL: legacyURL
        )
        await service.markForVerification(artist: "Portishead", album: "Dummy", reason: "missing_year")

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("Removing an album deletes it from SwiftData pending state")
    func removeFromPendingDeletesPersistedEntry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(container: container, directory: directory, date: baseDate)
        await service.markForVerification(artist: "Portishead", album: "Dummy", reason: "missing_year")
        #expect(await service.getEntry(artist: "Portishead", album: "Dummy") != nil)

        await service.removeFromPending(artist: "Portishead", album: "Dummy")

        let reloaded = makeService(container: container, directory: directory, date: baseDate)
        #expect(await reloaded.getEntry(artist: "Portishead", album: "Dummy") == nil)
        #expect(await reloaded.getAttemptCount(artist: "Portishead", album: "Dummy") == 0)
    }

    @Test("Auto verification timestamp persists across service instances")
    func autoVerifyTimestampPersists() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let initial = makeService(container: container, directory: directory, date: baseDate, autoVerifyDays: 14)
        #expect(await initial.shouldAutoVerify())

        try await initial.updateVerificationTimestamp()
        #expect(await !(initial.shouldAutoVerify()))

        let beforeInterval = makeService(
            container: container,
            directory: directory,
            date: baseDate.addingTimeInterval(13 * day),
            autoVerifyDays: 14
        )
        #expect(await !(beforeInterval.shouldAutoVerify()))

        let afterInterval = makeService(
            container: container,
            directory: directory,
            date: baseDate.addingTimeInterval(15 * day),
            autoVerifyDays: 14
        )
        #expect(await afterInterval.shouldAutoVerify())
    }

    @Test("Legacy JSON imports into SwiftData once")
    func legacyJSONImportsIntoSwiftData() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = PendingAlbumEntry(
            id: "legacy-entry",
            artist: "Low",
            album: "HEY WHAT",
            reason: "missing_year",
            attemptCount: 2,
            lastAttempt: baseDate,
            recheckInterval: 7 * day,
            metadata: ["source": "legacy"]
        )
        let envelope = LegacyPendingVerificationTestStore(
            entries: [entry],
            lastAutoVerification: baseDate
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let service = makeService(
            container: container,
            directory: directory,
            date: baseDate.addingTimeInterval(day),
            autoVerifyDays: 14,
            legacyStorageURL: legacyURL
        )
        try await service.initialize()

        let imported = try #require(await service.getEntry(artist: "Low", album: "HEY WHAT"))
        #expect(imported.attemptCount == 2)
        #expect(imported.metadata["source"] == "legacy")
        #expect(await !(service.shouldAutoVerify()))
    }

    @Test("Problematic albums report writes Python-compatible CSV columns")
    func problematicAlbumsReportWritesCSV() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let reportURL = directory.appendingPathComponent("exports/problematic.csv")

        let service = makeService(
            container: container,
            directory: directory,
            date: baseDate,
            verificationIntervalDays: 30
        )
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "Low", album: "HEY WHAT", reason: "missing_year")

        let count = try await service.generateProblematicAlbumsReport(minAttempts: 3, reportURL: reportURL)
        let csv = try String(contentsOf: reportURL, encoding: .utf8)

        #expect(count == 1)
        #expect(csv.contains("Artist,Album,First Attempt,Last Attempt,Total Attempts,Days Since First Attempt,Status"))
        #expect(csv.contains("\"Bjork, Solo\",Debut"))
        #expect(csv.contains(",3,"))
        #expect(!csv.contains("HEY WHAT"))
    }

    @Test("Problematic prerelease report uses the effective prerelease interval")
    func problematicPrereleaseReportUsesEffectiveRecheckInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")
        let reportURL = directory.appendingPathComponent("exports/problematic.csv")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lastAttempt = baseDate.addingTimeInterval(21 * day)
        let entry = PendingAlbumEntry(
            id: "legacy-prerelease-report",
            artist: "Slowdive",
            album: "Everything Is Alive",
            reason: "prerelease",
            attemptCount: 4,
            lastAttempt: lastAttempt,
            recheckInterval: 30 * day
        )
        let envelope = LegacyPendingVerificationTestStore(entries: [entry], lastAutoVerification: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let service = SwiftDataPendingVerificationService(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            problematicReportURL: reportURL,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { lastAttempt }
        )
        try await service.initialize()

        let count = try await service.generateProblematicAlbumsReport(minAttempts: 4, reportURL: reportURL)
        let csv = try String(contentsOf: reportURL, encoding: .utf8)

        #expect(count == 1)
        #expect(csv.contains(",4,21,Pending verification"))
    }
}
