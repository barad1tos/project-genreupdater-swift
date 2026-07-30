import AppKit
import ApplicationServices
import Core
import Foundation
import Services

extension RecoveryAvailability.Checks {
    /// Production probes: a running Music.app process, the Apple Events
    /// automation permission toward Music.app (never prompting), and the
    /// installed AppleScript set.
    @MainActor
    static func live(installer: ScriptInstaller?) -> Self {
        Self(
            isMusicAppRunning: {
                await MainActor.run {
                    NSWorkspace.shared.runningApplications
                        .contains { $0.bundleIdentifier == "com.apple.Music" }
                }
            },
            automationPermission: {
                automationPermissionToMusicApp()
            },
            areScriptsInstalled: {
                await installer?.areScriptsCurrent() ?? false
            }
        )
    }

    private static func automationPermissionToMusicApp() -> AutomationPermission {
        var musicAppDescriptor = AEAddressDesc()
        let bundleID = "com.apple.Music"
        let creation = bundleID.utf8CString.withUnsafeBufferPointer { pointer in
            AECreateDesc(
                typeApplicationBundleID,
                pointer.baseAddress,
                pointer.count - 1,
                &musicAppDescriptor
            )
        }
        guard creation == noErr else { return .undetermined }
        defer { AEDisposeDesc(&musicAppDescriptor) }
        let status = AEDeterminePermissionToAutomateTarget(
            &musicAppDescriptor,
            typeWildCard,
            typeWildCard,
            false
        )
        return switch status {
        case noErr:
            .granted
        case OSStatus(errAEEventNotPermitted):
            .denied
        default:
            .undetermined
        }
    }
}
