import Foundation

public enum RecoveryAvailabilityStatus: Equatable, Sendable {
    case available
    case blocked(RecoveryPreflightBlocker)
}

/// Probes whether live Music.app observation is currently possible.
///
/// Ranked: a stopped Music.app blocks first, then missing scripts. An
/// unanswerable probe (nil) fails open — the clearance path itself remains
/// fail-closed on real observation errors, mirroring the Python contract
/// where only the availability probe is optimistic. Automation permission is
/// deliberately not probed: writes run through `NSUserAppleScriptTask`
/// scripts the user installed, which carry their own consent.
public struct RecoveryAvailability: Sendable {
    public struct Checks: Sendable {
        public var isMusicAppRunning: @Sendable () async -> Bool?
        public var areScriptsInstalled: @Sendable () async -> Bool

        public init(
            isMusicAppRunning: @escaping @Sendable () async -> Bool?,
            areScriptsInstalled: @escaping @Sendable () async -> Bool
        ) {
            self.isMusicAppRunning = isMusicAppRunning
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
        if await checks.areScriptsInstalled() == false {
            return .blocked(.scriptsUnavailable)
        }
        return .available
    }
}
