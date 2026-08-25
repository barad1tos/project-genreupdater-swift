import Core
import Foundation
import Testing
@testable import Services

@Suite("Music.app mutation capability")
struct MusicAppMutationTests {
    @Test("Year mutations reject values the bundled writers cannot apply")
    func rejectsInvalidYears() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "database-101"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))

        for value in ["banana", "1800", "2029"] {
            #expect(throws: MusicTrackUpdateError.self) {
                try MusicTrackUpdate(databaseID: databaseID, property: .year, value: value, at: date)
            }
        }
        #expect(try MusicTrackUpdate(
            databaseID: databaseID,
            property: .year,
            value: "2028",
            at: date
        ).value == "2028")
        #expect(try MusicTrackUpdate(
            databaseID: databaseID,
            property: .year,
            value: String(MusicAppYear.missingValue),
            at: date
        ).value == "0")
    }

    @Test("Single mutation uses a canonical database identity and records its attempt")
    func singleMutationUsesCanonicalIdentity() async throws {
        let bridge = makeBridge()
        let attempts = MutationAttemptCounter()
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "database-101"))
        let update = musicUpdate(
            databaseID: databaseID,
            property: .genre,
            value: "Metal"
        )

        let result = try await bridge.applySingleUpdate(
            update,
            onAttempt: { await attempts.record() },
            execute: { "Success: Updated track database-101" }
        )

        #expect(result == .changed)
        #expect(await attempts.value == 1)
    }

    @Test("Batch verification keys tracks by canonical database identity")
    func batchVerificationUsesCanonicalIdentity() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "database-101"))
        let update = musicUpdate(
            databaseID: databaseID,
            property: .genre,
            value: "Metal"
        )
        let refreshed = Track(
            id: "catalog-source-101",
            name: "Only for the Weak",
            artist: "In Flames",
            album: "Clayman",
            genre: "Metal",
            appleScriptID: databaseID.rawValue
        )

        try AppleScriptBridge.verifyBatchUpdateValues([update], in: [refreshed])
    }

    @Test("Batch verification rejects unresolved canonical identities")
    func batchVerificationRejectsUnresolvedIdentity() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "database-101"))
        let update = musicUpdate(
            databaseID: databaseID,
            property: .genre,
            value: "Metal"
        )
        let unresolved = Track(
            id: databaseID.rawValue,
            name: "Only for the Weak",
            artist: "In Flames",
            album: "Clayman",
            genre: "Metal"
        )

        #expect(throws: MusicBatchVerificationError.self) {
            try AppleScriptBridge.verifyBatchUpdateValues([update], in: [unresolved])
        }
    }

    @Test("Batch verification rejects unexpected canonical identities")
    func batchVerificationRejectsUnexpectedIdentity() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "database-101"))
        let unexpectedID = try #require(MusicDatabaseTrackID(rawValue: "database-202"))
        let update = musicUpdate(
            databaseID: databaseID,
            property: .genre,
            value: "Metal"
        )
        let expected = Track(
            id: "catalog-source-101",
            name: "Only for the Weak",
            artist: "In Flames",
            album: "Clayman",
            genre: "Metal",
            appleScriptID: databaseID.rawValue
        )
        let unexpected = Track(
            id: "catalog-source-202",
            name: "Bullet Ride",
            artist: "In Flames",
            album: "Clayman",
            genre: "Metal",
            appleScriptID: unexpectedID.rawValue
        )

        #expect(throws: MusicBatchVerificationError.self) {
            try AppleScriptBridge.verifyBatchUpdateValues([update], in: [expected, unexpected])
        }
    }

    private func makeBridge() -> AppleScriptBridge {
        AppleScriptBridge(installer: ScriptInstaller(
            scriptsDirectory: FileManager.default.temporaryDirectory,
            bundleScriptsDirectory: nil
        ))
    }
}

private actor MutationAttemptCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}
