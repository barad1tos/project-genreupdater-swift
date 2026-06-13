// UpdateFlowTests.swift — XCUITests for the track update workflow.
//
// Tests the Update destination, configuration options, and menu command.
// Tests skip when onboarding or app setup prevents reaching the main shell.

import XCTest

final class UpdateFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchedApp() -> XCUIApplication {
        if let app {
            return app
        }

        app = XCUIApplication()
        app.launchArguments = [
            "-sidebarBadgesEnabled", "NO",
            "-sidebarCompact", "NO"
        ]
        app.launch()
        return app
    }

    // MARK: - Helpers

    /// Waits for the dashboard shell, skipping if onboarding or environment
    /// setup prevents reaching the main app.
    @MainActor
    private func waitForMainView() throws {
        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let dashboardLabel = mainWindow.staticTexts["Dashboard"]
        let libraryHealthLabel = mainWindow.staticTexts["Library Health"]
        let mainViewVisible = dashboardLabel.waitForExistence(timeout: 10)
            || libraryHealthLabel.waitForExistence(timeout: 5)

        try XCTSkipUnless(
            mainViewVisible,
            "Main view not reached (app may require onboarding or Music.app access)"
        )
    }

    /// Selects the Update destination from the sidebar.
    @MainActor
    private func selectUpdateView() throws {
        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        let updateButton = mainWindow.buttons["Update"]
        if updateButton.waitForExistence(timeout: 3) {
            updateButton.click()
            return
        }

        let updateLabel = mainWindow.staticTexts["Update"]
        XCTAssertTrue(
            updateLabel.waitForExistence(timeout: 5),
            "Sidebar should expose the Update destination"
        )
        updateLabel.click()
    }

    // MARK: - Sidebar Destination

    @MainActor
    func testUpdateDestinationExists() throws {
        try waitForMainView()

        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(
            mainWindow.staticTexts["Update"].exists || mainWindow.buttons["Update"].exists,
            "Sidebar should expose the Update destination"
        )
    }

    // MARK: - Update Screen

    @MainActor
    func testUpdateScreenAppears() throws {
        try waitForMainView()
        try selectUpdateView()

        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        let updateTitle = mainWindow.staticTexts["Update"]
        XCTAssertTrue(
            updateTitle.waitForExistence(timeout: 5),
            "Update screen should appear after selecting Update"
        )
    }

    @MainActor
    func testUpdateScreenHasConfigurationOptions() throws {
        try waitForMainView()
        try selectUpdateView()

        let app = launchedApp()
        let updateGenreToggle = app.checkBoxes["Update Genre"]
        let updateYearToggle = app.checkBoxes["Update Year"]

        // On macOS, toggles render as checkboxes. Try both accessors.
        let genreExists = updateGenreToggle.exists
            || app.staticTexts["Update Genre"].exists
        let yearExists = updateYearToggle.exists
            || app.staticTexts["Update Year"].exists

        XCTAssertTrue(genreExists, "Update Genre toggle should exist on the Update screen")
        XCTAssertTrue(yearExists, "Update Year toggle should exist on the Update screen")
    }

    @MainActor
    func testDryRunToggleExists() throws {
        try waitForMainView()
        try selectUpdateView()

        let app = launchedApp()
        let dryRunCheckbox = app.checkBoxes["Preview only (dry run)"]
        let dryRunLabel = app.staticTexts["Preview only (dry run)"]

        let dryRunExists = dryRunCheckbox.exists || dryRunLabel.exists
        XCTAssertTrue(
            dryRunExists,
            "Preview only (dry run) toggle should exist on the Update screen"
        )
    }

    // MARK: - Menu Command

    @MainActor
    func testUpdateMenuCommandExists() throws {
        try waitForMainView()

        let app = launchedApp()
        let menuBar = app.menuBars.firstMatch
        let updateMenu = menuBar.menuBarItems["Update"]

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

        app.typeKey(.escape, modifierFlags: [])
    }
}
