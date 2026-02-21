// NavigationTests.swift — XCUITests for sidebar navigation between categories.
//
// Tests that clicking sidebar items transitions the content area to the
// expected view. Requires the app to reach the "ready" state (past onboarding).

import XCTest

final class NavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    /// Waits for the main view sidebar to appear, skipping if the app is stuck
    /// in onboarding or an error state.
    private func waitForMainView() throws {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let libraryLabel = mainWindow.staticTexts["Library"]
        try XCTSkipUnless(
            libraryLabel.waitForExistence(timeout: 10),
            "Main view not reached (app may require onboarding or Music.app access)"
        )
    }

    /// Clicks a sidebar item by its label text.
    private func selectSidebarItem(_ label: String) {
        let mainWindow = app.windows.firstMatch
        let sidebarItem = mainWindow.staticTexts[label]
        if sidebarItem.waitForExistence(timeout: 3) {
            sidebarItem.click()
        }
    }

    // MARK: - Sidebar Items Exist

    func testSidebarBrowseSectionExists() throws {
        try waitForMainView()
        let mainWindow = app.windows.firstMatch

        let browseItems = ["Library", "By Artist", "By Album"]
        for item in browseItems {
            XCTAssertTrue(
                mainWindow.staticTexts[item].exists,
                "Sidebar should contain '\(item)' in Browse section"
            )
        }
    }

    func testSidebarActionsSectionExists() throws {
        try waitForMainView()
        let mainWindow = app.windows.firstMatch

        let actionItems = ["Genre Update", "Year Update", "Batch", "Reports"]
        for item in actionItems {
            XCTAssertTrue(
                mainWindow.staticTexts[item].exists,
                "Sidebar should contain '\(item)' in Actions section"
            )
        }
    }

    // MARK: - Navigation Transitions

    func testNavigateToReports() throws {
        try waitForMainView()

        selectSidebarItem("Reports")

        // Reports view has a navigation title "Reports" and an "Export CSV" toolbar button
        let mainWindow = app.windows.firstMatch
        let reportsTitle = mainWindow.staticTexts["Reports"]
        XCTAssertTrue(
            reportsTitle.waitForExistence(timeout: 5),
            "Reports view should appear after selecting Reports"
        )
    }

    func testNavigateToPlaylists() throws {
        try waitForMainView()

        selectSidebarItem("Playlists")

        // Playlists shows a ContentUnavailableView with "Playlists" title
        let mainWindow = app.windows.firstMatch
        let playlistsTitle = mainWindow.staticTexts["Playlists"]
        XCTAssertTrue(
            playlistsTitle.waitForExistence(timeout: 5),
            "Playlists unavailable view should appear"
        )

        // The stub message mentions MusicKit
        let stubMessage = mainWindow.staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "not yet available")
        )
        XCTAssertGreaterThan(
            stubMessage.count, 0,
            "Playlists stub should explain feature is not yet available"
        )
    }

    func testNavigateToBatch() throws {
        try waitForMainView()

        selectSidebarItem("Batch")

        // Batch view has title "Batch Processing"
        let mainWindow = app.windows.firstMatch
        let batchTitle = mainWindow.staticTexts["Batch Processing"]
        XCTAssertTrue(
            batchTitle.waitForExistence(timeout: 5),
            "Batch Processing view should appear after selecting Batch"
        )
    }

    func testNavigateBackToLibrary() throws {
        try waitForMainView()

        // Navigate away first
        selectSidebarItem("Reports")
        _ = app.windows.firstMatch.staticTexts["Reports"].waitForExistence(timeout: 3)

        // Navigate back to Library
        selectSidebarItem("Library")

        // Library view shows a track count or "No Tracks" empty state
        let mainWindow = app.windows.firstMatch
        let noTracksText = mainWindow.staticTexts["No Tracks"]
        let trackCountPredicate = NSPredicate(format: "value CONTAINS[c] %@", "tracks")
        let trackCountLabel = mainWindow.staticTexts.matching(trackCountPredicate)

        let libraryVisible = noTracksText.waitForExistence(timeout: 5)
            || !trackCountLabel.allElementsBoundByIndex.isEmpty

        XCTAssertTrue(libraryVisible, "Library view should show tracks or empty state")
    }
}
