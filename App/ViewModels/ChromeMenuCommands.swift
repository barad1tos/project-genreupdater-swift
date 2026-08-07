import Core
import Foundation
import Services

private let log = AppLogger.make(category: "chrome-menu")

/// Menu-bar dispatch for chrome commands (ADR 0010): the menu renders the
/// projection's descriptors, and dispatch revalidates against the current
/// projection before performing the typed operation.
extension AppDependencies {
    func performChromeCommand(_ kind: UserIntentCommandKind) async {
        let chrome = await projectionStore.currentChrome()
        guard let descriptor = chrome.commands.first(where: { $0.commandKind == kind }),
              descriptor.isEnabled
        else {
            log.info("Chrome menu command \(kind.rawValue, privacy: .public) no longer available; ignoring")
            return
        }
        switch kind {
        case .runManually:
            do {
                _ = try await submitManualRun()
            } catch {
                log.error("Menu run submission failed: \(error.localizedDescription, privacy: .public)")
            }
        case .resumeRecovery:
            guard let runID = chrome.safety.recoveryHold?.runID else {
                // Hold-only candidates carry no run snapshot; resolution
                // lives in the Activity surface (ADR 0006 repair flows).
                log.info("Resume recovery has no run identifier; open the app window to resolve")
                return
            }
            _ = await runRecoveryPreflight(runID: runID)
        default:
            log.error("Chrome menu received unsupported command kind \(kind.rawValue, privacy: .public)")
        }
        await refreshChromeProjection()
    }
}
