import Foundation
import Testing
@testable import Services

@Suite("Recovery availability probe")
struct RecoveryAvailabilityTests {
    @Test("all checks passing reports available")
    func reportsAvailable() async {
        let probe = RecoveryAvailability(checks: .passing)

        #expect(await probe.status() == .available)
    }

    @Test("a stopped Music.app blocks recovery first")
    func blocksOnStoppedMusicApp() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.isMusicAppRunning = { false }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.musicAppUnavailable))
    }

    @Test("missing scripts block recovery")
    func blocksOnMissingScripts() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.areScriptsInstalled = { false }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.scriptsUnavailable))
    }

    @Test("an unanswerable probe fails open for the command gate")
    func unanswerableProbeFailsOpen() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.isMusicAppRunning = { nil }

        #expect(await RecoveryAvailability(checks: checks).status() == .available)
    }

    @Test("blockers rank Music.app before scripts")
    func ranksBlockers() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.isMusicAppRunning = { false }
        checks.areScriptsInstalled = { false }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.musicAppUnavailable))
    }
}

extension RecoveryAvailability.Checks {
    static var passing: Self {
        Self(
            isMusicAppRunning: { true },
            areScriptsInstalled: { true }
        )
    }
}
