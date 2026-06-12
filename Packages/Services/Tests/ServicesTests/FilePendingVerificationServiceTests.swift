import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("FilePendingVerificationService - persistent pending albums")
struct FilePendingVerificationServiceTests {
    private let day: TimeInterval = 86400

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeService(
        directory: URL,
        date: Date,
        verificationIntervalDays: Int = 30,
        autoVerifyDays: Int = 14
    ) -> FilePendingVerificationService {
        FilePendingVerificationService(
            storageURL: directory.appendingPathComponent("pending.json"),
            problematicReportURL: directory.appendingPathComponent("problematic.csv"),
            verificationIntervalDays: verificationIntervalDays,
            autoVerifyDays: autoVerifyDays,
            currentDate: { date }
        )
    }

    @Test("Marking an album persists attempts, metadata, and recheck interval")
    func markForVerificationPersistsAndIncrementsAttempts() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(directory: directory, date: baseDate, verificationIntervalDays: 30)
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
            directory: directory,
            date: baseDate.addingTimeInterval(8 * day),
            verificationIntervalDays: 30
        )
        let persisted = try #require(await reloaded.getEntry(artist: "Massive Attack", album: "Mezzanine"))
        #expect(persisted.attemptCount == 2)
        #expect(persisted.metadata["source"] == "musicbrainz")
        #expect(await reloaded.isVerificationNeeded(artist: "Massive Attack", album: "Mezzanine"))
    }

    @Test("Removing an album deletes it from persisted pending state")
    func removeFromPendingDeletesPersistedEntry() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let service = makeService(directory: directory, date: baseDate)
        await service.markForVerification(artist: "Portishead", album: "Dummy", reason: "missing_year")
        #expect(await service.getEntry(artist: "Portishead", album: "Dummy") != nil)

        await service.removeFromPending(artist: "Portishead", album: "Dummy")

        let reloaded = makeService(directory: directory, date: baseDate)
        #expect(await reloaded.getEntry(artist: "Portishead", album: "Dummy") == nil)
        #expect(await reloaded.getAttemptCount(artist: "Portishead", album: "Dummy") == 0)
    }

    @Test("Auto verification timestamp persists across service instances")
    func autoVerifyTimestampPersists() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let initial = makeService(directory: directory, date: baseDate, autoVerifyDays: 14)
        #expect(await initial.shouldAutoVerify())

        try await initial.updateVerificationTimestamp()
        #expect(await !(initial.shouldAutoVerify()))

        let beforeInterval = makeService(
            directory: directory,
            date: baseDate.addingTimeInterval(13 * day),
            autoVerifyDays: 14
        )
        #expect(await !(beforeInterval.shouldAutoVerify()))

        let afterInterval = makeService(
            directory: directory,
            date: baseDate.addingTimeInterval(15 * day),
            autoVerifyDays: 14
        )
        #expect(await afterInterval.shouldAutoVerify())
    }

    @Test("Problematic albums report writes Python-compatible CSV columns")
    func problematicAlbumsReportWritesCSV() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let reportURL = directory.appendingPathComponent("exports/problematic.csv")

        let service = makeService(directory: directory, date: baseDate, verificationIntervalDays: 30)
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
}
