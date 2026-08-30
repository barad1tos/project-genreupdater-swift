// AppleScriptIntegrationTests.swift — Integration tests with real AppleScript execution
//
// These tests verify that AppleScript can communicate with Music.app.
// All operations are READ-ONLY — NEVER write to Music.app.
//
// Requirements:
// - Music.app must be running
// - Run locally only (not CI) — uses XCTSkipUnless for graceful degradation

import Core
import Foundation
import XCTest
@testable import Services

// MARK: - Music.app Accessibility Helper

/// Check whether Music.app is currently running by looking for it
/// in the process list via NSWorkspace.
///
/// This avoids launching Music.app just to run tests — if it is not
/// already open, the tests are skipped gracefully.
private func isMusicAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { application in
        application.bundleIdentifier == "com.apple.Music"
    }
}

/// Execute an AppleScript source string and return the result.
///
/// Uses `NSAppleScript` directly (not `NSUserAppleScriptTask`) so the
/// tests work without sandbox entitlements or installed script files.
/// This is intentional — integration tests should not depend on the
/// full app setup flow.
///
/// - Parameter source: AppleScript source code to execute.
/// - Returns: The string result, or `nil` if the script produced no output.
/// - Throws: If the script encounters an execution error.
@MainActor
private func executeAppleScript(_ source: String) throws -> String? {
    let script = NSAppleScript(source: source)
    var errorInfo: NSDictionary?
    let result = script?.executeAndReturnError(&errorInfo)

    if let errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        if message.localizedCaseInsensitiveContains("Not authorized to send Apple events to Music") {
            throw XCTSkip(
                "Apple Events permission for Music.app is not granted — skipping AppleScript integration tests."
            )
        }

        throw AppleScriptTestError.executionFailed(message)
    }

    return result?.stringValue
}

private func executeAppleScriptFile(_ scriptURL: URL, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [scriptURL.path] + arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        throw AppleScriptTestError.executionFailed(
            String(data: stderr, encoding: .utf8) ?? "osascript exited with status \(process.terminationStatus)"
        )
    }
    guard let result = String(data: stdout, encoding: .utf8) else {
        throw AppleScriptTestError.executionFailed("osascript returned non-UTF-8 output")
    }
    return result
}

// MARK: - Test Error

private enum AppleScriptTestError: Error, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executionFailed(detail):
            "AppleScript execution failed: \(detail)"
        }
    }
}

// MARK: - AppleScript Integration Tests

final class AppleScriptIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            isMusicAppRunning(),
            "Music.app is not running — skipping AppleScript integration tests. "
                + "Launch Music.app before running these tests."
        )
    }

    // MARK: - Connectivity Tests

    @MainActor
    func testMusicAppIsAccessible() throws {
        let result = try executeAppleScript(
            #"tell application "Music" to return name"#
        )

        XCTAssertEqual(
            result,
            "Music",
            "Expected Music.app to return its name 'Music'"
        )
    }

    @MainActor
    func testMusicAppReportsPlayerState() throws {
        let result = try executeAppleScript(
            #"tell application "Music" to return player state as text"#
        )

        XCTAssertNotNil(
            result,
            "Music.app should report a player state (playing, paused, or stopped)"
        )

        let validStates = Set(["playing", "paused", "stopped", "fast forwarding", "rewinding"])
        if let state = result {
            XCTAssertTrue(
                validStates.contains(state),
                "Player state '\(state)' is not a recognized Music.app state"
            )
        }
    }

    // MARK: - Track Read Tests (Non-Destructive)

    @MainActor
    func testReadTrackCount() throws {
        let result = try executeAppleScript(
            #"tell application "Music" to return count of tracks of library playlist 1"#
        )

        XCTAssertNotNil(result, "Expected a track count from Music.app library")

        if let countString = result, let count = Int(countString) {
            XCTAssertGreaterThan(
                count,
                0,
                "Expected at least 1 track in the Music library"
            )
        }
    }

    @MainActor
    func testReadFirstTrackName() throws {
        let result = try executeAppleScript(
            #"tell application "Music" to return name of track 1 of library playlist 1"#
        )

        XCTAssertNotNil(
            result,
            "Expected the first track to have a name"
        )

        if let trackName = result {
            XCTAssertFalse(
                trackName.isEmpty,
                "First track name should not be empty"
            )
        }
    }

    @MainActor
    func testReadFirstTrackArtist() throws {
        let result = try executeAppleScript(
            #"tell application "Music" to return artist of track 1 of library playlist 1"#
        )

        XCTAssertNotNil(
            result,
            "Expected the first track to have an artist"
        )
    }

    @MainActor
    func testReadMultipleTrackProperties() throws {
        // Read name, artist, and album of the first track in a single call
        // to verify that compound property reads work correctly.
        let result = try executeAppleScript("""
            tell application "Music"
                set firstTrack to track 1 of library playlist 1
                set trackName to name of firstTrack
                set trackArtist to artist of firstTrack
                set trackAlbum to album of firstTrack
                return trackName & " | " & trackArtist & " | " & trackAlbum
            end tell
        """)

        XCTAssertNotNil(
            result,
            "Expected combined track properties from Music.app"
        )

        if let combined = result {
            let parts = combined.components(separatedBy: " | ")
            XCTAssertEqual(
                parts.count,
                3,
                "Expected 3 pipe-separated fields (name, artist, album), got \(parts.count)"
            )
        }
    }

    @MainActor
    func testTrackIDCensusMatchesDeclaredCount() throws {
        let scriptURL = repositoryRoot.appendingPathComponent("Resources/Scripts/fetch_track_ids.applescript")
        let libraryURL = try requireDefaultMusicLibrary()

        let output = try executeAppleScriptFile(
            scriptURL,
            arguments: [libraryURL.path]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let liveCount = try XCTUnwrap(
            executeAppleScript(#"tell application "Music" to return count of tracks of library playlist 1"#)
                .flatMap(Int.init)
        )
        let fields = output.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        XCTAssertEqual(fields.first, "CENSUS", "The resource must emit the bulk census wire contract")
        let declaredCount = try XCTUnwrap(fields.count == 4 ? Int(fields[1]) : nil)
        let identifiers = fields[3].isEmpty
            ? []
            : fields[3].split(separator: ",", omittingEmptySubsequences: false)

        XCTAssertEqual(
            identifiers.count,
            declaredCount,
            "The census must contain every declared Music database ID"
        )
        XCTAssertEqual(
            declaredCount,
            liveCount,
            "The census must cover the complete Music database membership"
        )
    }

    @MainActor
    func testLibraryIdentitySnapshotMatchesMusicLibrary() throws {
        let scriptURL = repositoryRoot.appendingPathComponent(
            "Resources/Scripts/fetch_library_identity.applescript"
        )
        let libraryURL = try requireDefaultMusicLibrary()
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try executeAppleScriptFile(scriptURL, arguments: [libraryURL.path])
        let elapsed = startedAt.duration(to: clock.now)
        let snapshot = try LibraryIdentitySnapshot.decode(output)
        let liveCount = try XCTUnwrap(
            executeAppleScript(#"tell application "Music" to return count of tracks of library playlist 1"#)
                .flatMap(Int.init)
        )

        XCTAssertEqual(snapshot.census.totalCount, liveCount)
        XCTAssertEqual(snapshot.rows.count, liveCount)
        XCTAssertEqual(snapshot.rows.map(\.databaseID), snapshot.census.ids)
        XCTAssertLessThan(elapsed, .seconds(10), "Bulk identity snapshot exceeded its local regression ceiling")
    }

    @MainActor
    func testScopedMetadataSnapshotMatchesSelectedArtist() throws {
        let selectedArtist = "In Flames"
        let expectedIDs = try musicDatabaseIDs(for: selectedArtist)
        try XCTSkipUnless(!expectedIDs.isEmpty, "Selected integration-test artist is absent from Music.app")
        let scriptURL = repositoryRoot.appendingPathComponent("Resources/Scripts/fetch_scope_metadata.applescript")
        let libraryURL = try requireDefaultMusicLibrary()
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try executeAppleScriptFile(scriptURL, arguments: [libraryURL.path, selectedArtist])
        let elapsed = startedAt.duration(to: clock.now)
        let snapshot = try LibraryMetadataSnapshot.decode(output)

        XCTAssertEqual(Set(snapshot.tracks.compactMap(\.databaseID)), expectedIDs)
        XCTAssertLessThan(elapsed, .seconds(10), "Scoped metadata snapshot exceeded its local regression ceiling")
    }

    @MainActor
    func testFullMetadataSnapshotMatchesMusicLibrary() throws {
        let scriptURL = repositoryRoot.appendingPathComponent("Resources/Scripts/fetch_scope_metadata.applescript")
        let libraryURL = try requireDefaultMusicLibrary()
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try executeAppleScriptFile(scriptURL, arguments: [libraryURL.path, ""])
        let elapsed = startedAt.duration(to: clock.now)
        let snapshot = try LibraryMetadataSnapshot.decode(output)
        let liveCount = try XCTUnwrap(
            executeAppleScript(#"tell application "Music" to return count of tracks of library playlist 1"#)
                .flatMap(Int.init)
        )

        XCTAssertEqual(snapshot.tracks.count, liveCount)
        XCTAssertFalse(snapshot.generation.rawValue.isEmpty)
        XCTAssertLessThan(elapsed, .seconds(10), "Full metadata snapshot exceeded its local regression ceiling")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func requireDefaultMusicLibrary() throws -> URL {
        let libraryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Music/Music Library.musiclibrary")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: libraryURL.appendingPathComponent("Library.musicdb").path),
            "Default Music library database is unavailable"
        )
        return libraryURL
    }

    @MainActor
    private func musicDatabaseIDs(for artist: String) throws -> Set<MusicDatabaseTrackID> {
        let itemSeparator = String(UnicodeScalar(29))
        let output = try XCTUnwrap(executeAppleScript("""
        tell application "Music"
            set trackReference to a reference to (every track of library playlist 1 whose \
                (artist is "\(artist)") or (album artist is "\(artist)"))
            set databaseIDs to id of trackReference
        end tell
        set oldDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to ASCII character 29
        set resultText to databaseIDs as text
        set AppleScript's text item delimiters to oldDelimiters
        return resultText
        """))
        let rawIDs = output.isEmpty
            ? []
            : output.split(separator: Character(itemSeparator), omittingEmptySubsequences: false).map(String.init)
        return try Set(rawIDs.map { rawID in
            try XCTUnwrap(MusicDatabaseTrackID(rawValue: rawID))
        })
    }
}
