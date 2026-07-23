import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

private struct LegacyPendingVerificationTestStore: Codable {
    var entries: [PendingAlbumEntry]
    var lastAutoVerification: Date?
}

@Suite("PendingVerificationStore - persistent pending albums")
struct PendingVerificationStoreTests {
    private let day: TimeInterval = 86400

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeService(
        container: ModelContainer,
        date: Date,
        verificationIntervalDays: Int = 30,
        autoVerifyDays: Int = 14,
        prereleaseRecheckDays: Int? = nil,
        legacyStorageURL: URL? = nil
    ) -> PendingVerificationStore {
        PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyStorageURL,
            verificationIntervalDays: verificationIntervalDays,
            prereleaseRecheckDays: prereleaseRecheckDays,
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

        let service = makeService(container: container, date: baseDate)
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

        let service = PendingVerificationStore(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate }
        )
        await service.markForVerification(artist: "Slowdive", album: "Everything Is Alive", reason: "prerelease")

        let entry = try #require(await service.getEntry(artist: "Slowdive", album: "Everything Is Alive"))
        #expect(entry.recheckInterval == 7 * day)
        #expect(entry.metadata["recheck_days"] == "7")

        let beforeRecheck = PendingVerificationStore(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate.addingTimeInterval(6 * day) }
        )
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive")))

        let afterRecheck = PendingVerificationStore(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate.addingTimeInterval(7 * day) }
        )
        #expect(await afterRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive"))
    }

    @Test("Generic pending marks preserve existing prerelease reason")
    func genericPendingMarksPreserveExistingPrereleaseReason() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: nil,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate }
        )
        await service.markForVerification(artist: "Daft Punk", album: "Future Memories", reason: "prerelease")
        await service.markForVerification(artist: "Daft Punk", album: "Future Memories", reason: "no_year_found")

        let entry = try #require(await service.getEntry(artist: "Daft Punk", album: "Future Memories"))
        #expect(entry.reason == "prerelease")
        #expect(entry.attemptCount == 2)
        #expect(entry.recheckInterval == 7 * day)
        #expect(entry.metadata["recheck_days"] == "7")
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

        let initial = PendingVerificationStore(
            modelContainer: container,
            configuration: configuration,
            baseDirectory: directory,
            currentDate: { baseDate }
        )
        await initial.markForVerification(artist: "Portishead", album: "Dummy", reason: "no_year_found")
        await initial.markForVerification(artist: "Slowdive", album: "Everything Is Alive", reason: "prerelease")

        let afterPrereleaseInterval = PendingVerificationStore(
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
            retry: .init(
                attemptCount: 1,
                lastAttempt: baseDate,
                recheckInterval: 30 * day
            )
        )
        let envelope = LegacyPendingVerificationTestStore(entries: [entry], lastAutoVerification: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let beforeRecheck = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate.addingTimeInterval(6 * day) }
        )
        try await beforeRecheck.initialize()
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive")))

        let afterRecheck = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate.addingTimeInterval(7 * day) }
        )
        #expect(await afterRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive"))
    }

    @Test("Invalid prerelease recheck metadata falls back to configured interval")
    func invalidPrereleaseRecheckMetadataFallsBackToConfiguredInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending_year_verification.csv")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let csv = """
        artist,album,timestamp,reason,metadata,attempt_count
        Slowdive,Everything Is Alive,2023-11-14 22:13:20,prerelease,"{""recheck_days"":0}",1
        """
        try csv.write(to: legacyURL, atomically: true, encoding: .utf8)

        let beforeRecheck = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { baseDate.addingTimeInterval(6 * day) }
        )
        try await beforeRecheck.initialize()

        let imported = try #require(await beforeRecheck.getEntry(artist: "Slowdive", album: "Everything Is Alive"))
        #expect(imported.metadata["recheck_days"] == "0")
        #expect(imported.recheckInterval == 7 * day)
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Slowdive", album: "Everything Is Alive")))
        #expect(await !(beforeRecheck.isVerificationNeeded(artist: "Missing", album: "Album")))

        let afterRecheck = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyURL,
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

        let service = makeService(container: container, date: baseDate)
        await service.markForVerification(artist: "Portishead", album: "Dummy", reason: "missing_year")
        #expect(await service.getEntry(artist: "Portishead", album: "Dummy") != nil)

        await service.removeFromPending(artist: "Portishead", album: "Dummy")

        let reloaded = makeService(container: container, date: baseDate)
        #expect(await reloaded.getEntry(artist: "Portishead", album: "Dummy") == nil)
        #expect(await reloaded.getAttemptCount(artist: "Portishead", album: "Dummy") == 0)
    }

    @Test("Auto verification timestamp persists across service instances")
    func autoVerifyTimestampPersists() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let initial = makeService(container: container, date: baseDate, autoVerifyDays: 14)
        #expect(await initial.shouldAutoVerify())

        try await initial.updateVerificationTimestamp()
        #expect(await !(initial.shouldAutoVerify()))

        let beforeInterval = makeService(
            container: container,
            date: baseDate.addingTimeInterval(13 * day),
            autoVerifyDays: 14
        )
        #expect(await !(beforeInterval.shouldAutoVerify()))

        let afterInterval = makeService(
            container: container,
            date: baseDate.addingTimeInterval(15 * day),
            autoVerifyDays: 14
        )
        #expect(await afterInterval.shouldAutoVerify())

        // Disabled interval (autoVerifyDays: 0) → never auto-verify, even after elapsed time
        let disabled = makeService(
            container: container,
            date: baseDate.addingTimeInterval(100 * day),
            autoVerifyDays: 0
        )
        #expect(await !(disabled.shouldAutoVerify()))
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
            retry: .init(
                attemptCount: 2,
                lastAttempt: baseDate,
                recheckInterval: 7 * day
            ),
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

    @Test("Legacy entries with raw artist/album keys migrate to normalized lookup keys")
    func legacyEntriesWithRawKeysMigrateToNormalizedLookupKeys() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let rawEntries = [
            PendingAlbumEntry(
                id: "legacy-raw-1",
                artist: "  PINK FLOYD  ",
                album: "  The Wall  ",
                reason: "no_year_found",
                retry: .init(
                    attemptCount: 1,
                    lastAttempt: baseDate,
                    recheckInterval: 30 * day
                ),
                metadata: ["source": "legacy"]
            ),
            PendingAlbumEntry(
                id: "legacy-raw-2",
                artist: "BJÖRK",
                album: "Debut",
                reason: "prerelease",
                retry: .init(
                    attemptCount: 2,
                    lastAttempt: baseDate,
                    recheckInterval: 7 * day
                ),
                metadata: [:]
            ),
        ]
        let envelope = LegacyPendingVerificationTestStore(entries: rawEntries, lastAutoVerification: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let service = makeService(
            container: container,
            date: baseDate.addingTimeInterval(day),
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            legacyStorageURL: legacyURL
        )
        try await service.initialize()

        // Clean lookups find raw-keyed entries after normalization
        let pinkFloyd = try #require(await service.getEntry(artist: "Pink Floyd", album: "The Wall"))
        #expect(pinkFloyd.reason == "no_year_found")
        #expect(pinkFloyd.attemptCount == 1)
        #expect(pinkFloyd.metadata["source"] == "legacy")
        // Migration preserves raw legacy artist/album display values
        #expect(pinkFloyd.artist == "  PINK FLOYD  ")
        #expect(pinkFloyd.album == "  The Wall  ")

        let bjork = try #require(await service.getEntry(artist: "Bjork", album: "Debut"))
        #expect(bjork.reason == "prerelease")
        #expect(bjork.attemptCount == 2)

        // Marking with a different case/whitespace variant increments the existing entry
        await service.markForVerification(artist: "pink floyd", album: "the wall", reason: "no_year_found")
        let incremented = try #require(await service.getEntry(artist: "PINK FLOYD", album: "The Wall"))
        #expect(incremented.attemptCount == 2)
        // Re-marking with a clean variant trims and updates stored display values
        #expect(incremented.artist == "pink floyd")
        #expect(incremented.album == "the wall")
    }

    @Test("Python pending CSV imports into SwiftData")
    func pythonPendingCSVImportsIntoSwiftData() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending_year_verification.csv")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let csv = """
        artist,album,timestamp,reason,metadata,attempt_count
        "Bjork, Solo",Debut,2023-11-14 22:13:20,prerelease,"{""source"":""python"",""recheck_days"":7}",4
        Low,HEY WHAT,2023-11-14,no_year_found,,2
        Coil,Wrong,2023-11-14,unknown_reason,,1
        """
        try csv.write(to: legacyURL, atomically: true, encoding: .utf8)

        let service = makeService(
            container: container,
            date: baseDate.addingTimeInterval(8 * day),
            verificationIntervalDays: 30,
            legacyStorageURL: legacyURL
        )
        try await service.initialize()

        let prerelease = try #require(await service.getEntry(artist: "Bjork, Solo", album: "Debut"))
        #expect(prerelease.reason == "prerelease")
        #expect(prerelease.attemptCount == 4)
        #expect(prerelease.metadata["source"] == "python")
        #expect(prerelease.metadata["recheck_days"] == "7")
        #expect(await service.isVerificationNeeded(artist: "Bjork, Solo", album: "Debut"))

        let missingYear = try #require(await service.getEntry(artist: "Low", album: "HEY WHAT"))
        #expect(missingYear.reason == "no_year_found")
        #expect(missingYear.attemptCount == 2)
        #expect(missingYear.metadata.isEmpty)

        let unknownReason = try #require(await service.getEntry(artist: "Coil", album: "Wrong"))
        #expect(unknownReason.reason == "no_year_found")
    }

    @Test("Problematic pending albums expose typed report rows")
    func problematicPendingAlbumsExposeTypedReportRows() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(
            container: container,
            date: baseDate,
            verificationIntervalDays: 30
        )
        await service.markForVerification(artist: "Low", album: "HEY WHAT", reason: "missing_year")
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "Bjork, Solo", album: "Debut", reason: "missing_year")
        await service.markForVerification(artist: "The Cure", album: "Wish", reason: "missing_year")
        await service.markForVerification(artist: "The Cure", album: "Wish", reason: "missing_year")
        await service.markForVerification(artist: "The Cure", album: "Wish", reason: "missing_year")
        await service.markForVerification(artist: "The Cure", album: "Wish", reason: "missing_year")

        let rows = await service.getProblematicPendingAlbums(minAttempts: 3)

        #expect(rows.map(\.entry.album) == ["Wish", "Debut"])
        #expect(rows.map(\.totalAttempts) == [4, 3])
        #expect(rows[0].firstAttempt == baseDate.addingTimeInterval(-90 * 86400))
        #expect(rows[0].lastAttempt == baseDate)
        #expect(rows[0].daysSinceFirstAttempt == 90)
        #expect(rows[0].status == "Pending verification")
    }

    @Test("Problematic prerelease rows use the effective prerelease interval")
    func problematicPrereleaseRowsUseEffectiveRecheckInterval() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainerFactory.createInMemory()
        let legacyURL = directory.appendingPathComponent("pending.json")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lastAttempt = baseDate.addingTimeInterval(21 * day)
        let entry = PendingAlbumEntry(
            id: "legacy-prerelease-report",
            artist: "Slowdive",
            album: "Everything Is Alive",
            reason: "prerelease",
            retry: .init(
                attemptCount: 4,
                lastAttempt: lastAttempt,
                recheckInterval: 30 * day
            )
        )
        let envelope = LegacyPendingVerificationTestStore(entries: [entry], lastAutoVerification: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(envelope).write(to: legacyURL, options: .atomic)

        let service = PendingVerificationStore(
            modelContainer: container,
            legacyStorageURL: legacyURL,
            verificationIntervalDays: 30,
            prereleaseRecheckDays: 7,
            currentDate: { lastAttempt }
        )
        try await service.initialize()

        let rows = await service.getProblematicPendingAlbums(minAttempts: 4)

        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.totalAttempts == 4)
        #expect(row.daysSinceFirstAttempt == 21)
        #expect(row.status == "Pending verification")
    }
}
