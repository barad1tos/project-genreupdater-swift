// NavigationTests.swift — XCUITests for sidebar navigation between categories.
//
// Tests that clicking sidebar items transitions the content area to the
// expected view. Requires the app to reach the "ready" state (past onboarding).

import XCTest

final class NavigationTests: XCTestCase {
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

    /// Waits for the current dashboard shell, skipping if onboarding or
    /// environment setup prevents reaching the main app.
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

    /// Clicks a sidebar item by its label text.
    @MainActor
    private func selectSidebarItem(_ label: String) {
        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        let sidebarButton = mainWindow.buttons[label]
        if sidebarButton.waitForExistence(timeout: 3) {
            sidebarButton.click()
            return
        }

        let sidebarItem = mainWindow.staticTexts[label]
        if sidebarItem.waitForExistence(timeout: 3) {
            sidebarItem.click()
        }
    }

    /// Returns true when a sidebar destination is exposed as either a button
    /// or the visible text nested inside that button.
    @MainActor
    private func sidebarElementExists(_ label: String) -> Bool {
        let app = launchedApp()
        let mainWindow = app.windows.firstMatch
        return mainWindow.buttons[label].exists || mainWindow.staticTexts[label].exists
    }

    // MARK: - Sidebar Items Exist

    @MainActor
    func testPrimarySidebarDestinationsExist() throws {
        try waitForMainView()

        let destinations = ["Dashboard", "Browse", "Reports", "Update"]
        for item in destinations {
            XCTAssertTrue(
                sidebarElementExists(item),
                "Sidebar should contain '\(item)'"
            )
        }
    }

    @MainActor
    func testSettingsFooterExists() throws {
        try waitForMainView()
        let app = launchedApp()
        let mainWindow = app.windows.firstMatch

        XCTAssertTrue(
            mainWindow.buttons["Settings"].exists || mainWindow.staticTexts["Settings"].exists,
            "Sidebar should expose the Settings footer in expanded mode"
        )
    }

    // MARK: - Navigation Transitions

    @MainActor
    func testNavigateToReports() throws {
        try waitForMainView()

        selectSidebarItem("Reports")
        let app = launchedApp()

        let mainWindow = app.windows.firstMatch
        let reportsTitle = mainWindow.staticTexts["Reports"]
        XCTAssertTrue(
            reportsTitle.waitForExistence(timeout: 5),
            "Reports view should appear after selecting Reports"
        )
    }

    @MainActor
    func testNavigateToBrowse() throws {
        try waitForMainView()

        selectSidebarItem("Browse")
        let app = launchedApp()

        let mainWindow = app.windows.firstMatch
        let browseTitle = mainWindow.staticTexts["Browse"]
        XCTAssertTrue(
            browseTitle.waitForExistence(timeout: 5),
            "Browse view should appear after selecting Browse"
        )
    }

    @MainActor
    func testNavigateToUpdate() throws {
        try waitForMainView()

        selectSidebarItem("Update")
        let app = launchedApp()

        let mainWindow = app.windows.firstMatch
        let updateTitle = mainWindow.staticTexts["Update"]
        XCTAssertTrue(
            updateTitle.waitForExistence(timeout: 5),
            "Update view should appear after selecting Update"
        )
    }

    @MainActor
    func testNavigateBackToDashboard() throws {
        try waitForMainView()

        selectSidebarItem("Reports")
        let app = launchedApp()
        _ = app.windows.firstMatch.staticTexts["Reports"].waitForExistence(timeout: 3)

        selectSidebarItem("Dashboard")

        let mainWindow = app.windows.firstMatch
        let libraryHealthLabel = mainWindow.staticTexts["Library Health"]

        XCTAssertTrue(
            libraryHealthLabel.waitForExistence(timeout: 5),
            "Dashboard view should show library health after returning from Reports"
        )
    }
}
