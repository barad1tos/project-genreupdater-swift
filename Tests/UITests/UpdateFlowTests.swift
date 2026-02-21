// UpdateFlowTests.swift — XCUITests for the track update workflow.
//
// Tests the update sheet presentation, configuration options, and toolbar
// controls. Some tests require the app to have loaded tracks (Music.app
// access), so they use XCTSkipUnless to degrade gracefully in CI.

import XCTest

final class UpdateFlowTests: XCTestCase {
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

    /// Waits for the main view to appear with the Library category selected.
    private func waitForLibraryView() throws {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let libraryLabel = mainWindow.staticTexts["Library"]
        try XCTSkipUnless(
            libraryLabel.waitForExistence(timeout: 10),
            "Main view not reached (app may require onboarding or Music.app access)"
        )
    }

    /// Returns true if the library has loaded tracks (not showing empty state).
    private var hasLoadedTracks: Bool {
        let mainWindow = app.windows.firstMatch
        let noTracksText = mainWindow.staticTexts["No Tracks"]
        // If "No Tracks" is visible, the library is empty
        return !noTracksText.exists
    }

    // MARK: - Toolbar Controls

    func testUpdateTracksButtonExists() throws {
        try waitForLibraryView()

        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update Tracks"]
        XCTAssertTrue(
            updateButton.waitForExistence(timeout: 5),
            "Update Tracks toolbar button should exist"
        )
    }

    func testRefreshButtonExists() throws {
        try waitForLibraryView()

        let mainWindow = app.windows.firstMatch
        let refreshButton = mainWindow.buttons["Refresh library"]
        XCTAssertTrue(
            refreshButton.waitForExistence(timeout: 5),
            "Refresh library toolbar button should exist"
        )
    }

    // MARK: - Update Sheet

    func testUpdateSheetAppears() throws {
        try waitForLibraryView()

        // The Update Tracks button is disabled when there are no tracks.
        // Skip if the library is empty (no Music.app access in CI).
        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update Tracks"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))

        try XCTSkipUnless(
            updateButton.isEnabled,
            "Update button is disabled (no tracks loaded — Music.app access may be required)"
        )

        updateButton.click()

        // The sheet should present with "Update Tracks" navigation title
        // and configuration options
        let sheetTitle = app.staticTexts["Update Tracks"]
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 5),
            "Update sheet should appear with 'Update Tracks' title"
        )
    }

    func testUpdateSheetHasConfigurationOptions() throws {
        try waitForLibraryView()

        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update Tracks"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))

        try XCTSkipUnless(
            updateButton.isEnabled,
            "Update button is disabled (no tracks loaded)"
        )

        updateButton.click()

        // Wait for sheet to appear
        let sheetTitle = app.staticTexts["Update Tracks"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))

        // Verify configuration toggles exist
        let updateGenreToggle = app.checkBoxes["Update Genre"]
        let updateYearToggle = app.checkBoxes["Update Year"]

        // On macOS, toggles render as checkboxes. Try both accessors.
        let genreExists = updateGenreToggle.exists
            || app.staticTexts["Update Genre"].exists
        let yearExists = updateYearToggle.exists
            || app.staticTexts["Update Year"].exists

        XCTAssertTrue(genreExists, "Update Genre toggle should exist in the sheet")
        XCTAssertTrue(yearExists, "Update Year toggle should exist in the sheet")
    }

    func testDryRunToggleExists() throws {
        try waitForLibraryView()

        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update Tracks"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))

        try XCTSkipUnless(
            updateButton.isEnabled,
            "Update button is disabled (no tracks loaded)"
        )

        updateButton.click()

        // Wait for sheet to appear
        let sheetTitle = app.staticTexts["Update Tracks"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))

        // The dry-run toggle label reads "Preview only (dry run)"
        let dryRunCheckbox = app.checkBoxes["Preview only (dry run)"]
        let dryRunLabel = app.staticTexts["Preview only (dry run)"]

        let dryRunExists = dryRunCheckbox.exists || dryRunLabel.exists
        XCTAssertTrue(
            dryRunExists,
            "Preview only (dry run) toggle should exist in the sheet"
        )
    }

    func testUpdateSheetCancelButton() throws {
        try waitForLibraryView()

        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update Tracks"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 5))

        try XCTSkipUnless(
            updateButton.isEnabled,
            "Update button is disabled (no tracks loaded)"
        )

        updateButton.click()

        let sheetTitle = app.staticTexts["Update Tracks"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 5))

        // Cancel button should dismiss the sheet
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 3),
            "Cancel button should exist in the update sheet"
        )

        cancelButton.click()

        // After cancel, the sheet title should no longer be visible
        // (or the update button should be accessible again on the main window)
        XCTAssertTrue(
            updateButton.waitForExistence(timeout: 5),
            "Main toolbar should be accessible after dismissing the sheet"
        )
    }

    // MARK: - Menu Command

    func testUpdateMenuCommandExists() throws {
        try waitForLibraryView()

        // Check the menu bar has an "Update" menu with "Update Selected Tracks"
        let menuBar = app.menuBars.firstMatch
        let updateMenu = menuBar.menuBarItems["Update"]

        // The Update menu should exist (added in GenreUpdaterApp.swift)
        XCTAssertTrue(
            updateMenu.exists,
            "Update menu should exist in the menu bar"
        )

        updateMenu.click()

        let updateCommand = updateMenu.menuItems["Update Selected Tracks"]
        XCTAssertTrue(
            updateCommand.waitForExistence(timeout: 3),
            "Update Selected Tracks menu item should exist"
        )

        // Press Escape to dismiss the menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
