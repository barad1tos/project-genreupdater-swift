import Foundation

/// Automation (Apple Events) permission state toward Music.app.
public enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    case undetermined
}

public enum RecoveryAvailabilityStatus: Equatable, Sendable {
    case available
    case blocked(RecoveryPreflightBlocker)
}

/// Probes whether live Music.app observation is currently possible.
///
/// Ranked: a stopped Music.app blocks first, then a denied automation
/// permission, then missing scripts. An undetermined permission stays
/// available so the system prompt can appear on first use, and a probe that
/// cannot answer (nil) fails open — the clearance path itself remains
/// fail-closed on real observation errors, mirroring the Python contract
/// where only the availability probe is optimistic.
public struct RecoveryAvailability: Sendable {
    public struct Checks: Sendable {
        public var isMusicAppRunning: @Sendable () async -> Bool?
        public var automationPermission: @Sendable () async -> AutomationPermission
        public var areScriptsInstalled: @Sendable () async -> Bool

        public init(
            isMusicAppRunning: @escaping @Sendable () async -> Bool?,
            automationPermission: @escaping @Sendable () async -> AutomationPermission,
            areScriptsInstalled: @escaping @Sendable () async -> Bool
        ) {
            self.isMusicAppRunning = isMusicAppRunning
            self.automationPermission = automationPermission
            self.areScriptsInstalled = areScriptsInstalled
        }
    }

    private let checks: Checks

    public init(checks: Checks) {
        self.checks = checks
    }

    public func status() async -> RecoveryAvailabilityStatus {
        if await checks.isMusicAppRunning() == false {
            return .blocked(.musicAppUnavailable)
        }
        if await checks.automationPermission() == .denied {
            return .blocked(.automationPermissionDenied)
        }
        if await checks.areScriptsInstalled() == false {
            return .blocked(.scriptsUnavailable)
        }
        return .available
    }
}
