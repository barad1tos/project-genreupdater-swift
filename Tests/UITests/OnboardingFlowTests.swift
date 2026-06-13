// OnboardingFlowTests.swift — XCUITests for app launch and onboarding flow.
//
// Validates that the app launches successfully, the main window exists,
// and the primary navigation structure is present. These tests run against
// the full app binary and do not require Music.app access.

import XCTest

final class OnboardingFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Launch

    func testAppLaunches() {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.exists, "Main window should exist after launch")
    }

    func testMainWindowHasMinimumSize() {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        let frame = mainWindow.frame
        XCTAssertGreaterThanOrEqual(frame.width, 800, "Window width should be at least 800pt")
        XCTAssertGreaterThanOrEqual(frame.height, 600, "Window height should be at least 600pt")
    }

    // MARK: - Initial View State

    func testInitialViewAppears() {
        // The app shows either onboarding or the main view depending on state.
        // Both contain recognizable UI elements within the window.
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        // At minimum, one of these states should be visible:
        // - Loading indicator ("Initializing...")
        // - Onboarding welcome ("Welcome to Genre Updater")
        // - Main sidebar ("Library" label)
        // - Error view ("Something went wrong")
        let loadingText = mainWindow.staticTexts["Initializing..."]
        let welcomeText = mainWindow.staticTexts["Welcome to Genre Updater"]
        let libraryLabel = mainWindow.staticTexts["Library"]
        let errorText = mainWindow.staticTexts["Something went wrong"]

        let anyStateVisible = loadingText.waitForExistence(timeout: 3)
            || welcomeText.exists
            || libraryLabel.exists
            || errorText.exists

        XCTAssertTrue(anyStateVisible, "App should display a recognizable initial state")
    }

    // MARK: - Onboarding (if shown)

    func testOnboardingGetStartedButtonExists() throws {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let welcomeText = mainWindow.staticTexts["Welcome to Genre Updater"]
        try XCTSkipUnless(
            welcomeText.waitForExistence(timeout: 5),
            "Onboarding not shown (scripts may already be installed)"
        )

        let getStartedButton = mainWindow.buttons["Get Started"]
        XCTAssertTrue(
            getStartedButton.waitForExistence(timeout: 3),
            "Get Started button should appear on the welcome step"
        )
    }

    func testOnboardingStepIndicatorVisible() throws {
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))

        let welcomeText = mainWindow.staticTexts["Welcome to Genre Updater"]
        try XCTSkipUnless(
            welcomeText.waitForExistence(timeout: 5),
            "Onboarding not shown (scripts may already be installed)"
        )

        // Step indicator shows step names: "Welcome", "Install Scripts", "Music Access"
        let welcomeStep = mainWindow.staticTexts["Welcome"]
        let installStep = mainWindow.staticTexts["Install Scripts"]
        let musicStep = mainWindow.staticTexts["Music Access"]

        XCTAssertTrue(welcomeStep.exists, "Welcome step indicator should be visible")
        XCTAssertTrue(installStep.exists, "Install Scripts step indicator should be visible")
        XCTAssertTrue(musicStep.exists, "Music Access step indicator should be visible")
    }
}
