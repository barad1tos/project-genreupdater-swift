import AppKit
import Core
import Foundation
import Services

extension RecoveryAvailability.Checks {
    /// Production probes: a running Music.app process and the installed
    /// AppleScript set. Automation permission is deliberately not probed —
    /// writes run through `NSUserAppleScriptTask` scripts the user installed,
    /// so no direct Apple Events permission applies to this process.
    static func live(installer: ScriptInstaller) -> Self {
        Self(
            isMusicAppRunning: {
                await MainActor.run {
                    NSWorkspace.shared.runningApplications
                        .contains { $0.bundleIdentifier == "com.apple.Music" }
                }
            },
            areScriptsInstalled: {
                await installer.areScriptsCurrent()
            }
        )
    }
}
