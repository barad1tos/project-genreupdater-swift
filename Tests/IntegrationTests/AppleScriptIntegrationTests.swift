// AppleScriptIntegrationTests.swift — Integration tests with real AppleScript execution
//
// These tests verify that AppleScript can communicate with Music.app.
// All operations are READ-ONLY — NEVER write to Music.app.
//
// Requirements:
// - Music.app must be running
// - Run locally only (not CI) — uses XCTSkipUnless for graceful degradation

import Foundation
import XCTest

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
        throw AppleScriptTestError.executionFailed(message)
    }

    return result?.stringValue
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

        let validStates: Set<String> = ["playing", "paused", "stopped", "fast forwarding", "rewinding"]
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
}
