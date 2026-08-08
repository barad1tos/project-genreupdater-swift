import Core
import Foundation
import Services

private let log = AppLogger.make(category: "chrome-menu")

/// Menu-bar dispatch for chrome commands (ADR 0010): the menu renders the
/// projection's descriptors, and dispatch revalidates against the current
/// projection before performing the typed operation. Slice 10 routes this
/// through ActivityCommands so menu outcomes render as typed results.
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
            await performMenuRun()
        case .resumeRecovery:
            await performMenuRecoveryResume(chrome: chrome)
        case .acceptFixPlan,
             .applyFixPlan,
             .applyRemainingFixes,
             .continueWrites,
             .dismissRecoveryItem,
             .dismissRecoveryItems,
             .rejectFixPlan,
             .requestAlbumPreview,
             .reviewChanges,
             .togglePlanItem:
            log.error("Chrome menu received unsupported command kind \(kind.rawValue, privacy: .public)")
        }
        await refreshChromeProjection()
    }

    private func performMenuRun() async {
        do {
            let result = try await submitManualRun()
            log.info("Menu run submission outcome: \(String(describing: result), privacy: .public)")
        } catch {
            log.error("Menu run submission failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performMenuRecoveryResume(chrome: ChromeProjection) async {
        guard let runID = chrome.safety.recoveryHold?.runID else {
            // Hold-only candidates carry no run snapshot; resolution
            // lives in the Activity surface (ADR 0006 repair flows).
            log.info("Resume recovery has no run identifier; open the app window to resolve")
            return
        }
        let outcome = await runRecoveryPreflight(runID: runID)
        log.info("Menu recovery preflight outcome: \(String(describing: outcome), privacy: .public)")
        if case .resolved = outcome {
            // Mirrors the host view's resolved path: item states live in
            // the reports projection, and the view applies this publish
            // through its projection stream.
            await republishReportsProjection()
        }
    }

    /// Store-published reports refresh usable outside the host view.
    private func republishReportsProjection() async {
        let inputGeneration = await projectionStore.nextReportsProjectionInputGeneration()
        guard let page = await loadRunReportPage(limit: RunHistoryAdapter.runHistoryLimit) else { return }
        let lifecycle = await currentRunLifecycle()
        let activeRunID = lifecycle?.isActive == true ? lifecycle?.runID : nil
        let projection = ReportsBuilder.makeProjection(from: RunHistoryAdapter.makeInput(
            from: page,
            now: Date(),
            activeRunID: activeRunID
        ))
        _ = await projectionStore.replaceReportsProjection(projection, inputGeneration: inputGeneration)
    }
}
