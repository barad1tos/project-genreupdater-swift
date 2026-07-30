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

    @Test("denied automation permission blocks recovery")
    func blocksOnDeniedAutomation() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.automationPermission = { .denied }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.automationPermissionDenied))
    }

    @Test("missing scripts block recovery")
    func blocksOnMissingScripts() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.areScriptsInstalled = { false }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.scriptsUnavailable))
    }

    @Test("an undetermined automation permission stays available for prompting")
    func staysAvailableWhenUndetermined() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.automationPermission = { .undetermined }

        #expect(await RecoveryAvailability(checks: checks).status() == .available)
    }

    @Test("a probe timeout fails open for the command gate")
    func probeTimeoutFailsOpen() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.isMusicAppRunning = { nil }

        #expect(await RecoveryAvailability(checks: checks).status() == .available)
    }

    @Test("blockers rank Music.app before permission before scripts")
    func ranksBlockers() async {
        var checks = RecoveryAvailability.Checks.passing
        checks.isMusicAppRunning = { false }
        checks.automationPermission = { .denied }
        checks.areScriptsInstalled = { false }

        #expect(await RecoveryAvailability(checks: checks).status() == .blocked(.musicAppUnavailable))
    }
}

extension RecoveryAvailability.Checks {
    static var passing: Self {
        Self(
            isMusicAppRunning: { true },
            automationPermission: { .granted },
            areScriptsInstalled: { true }
        )
    }
}
