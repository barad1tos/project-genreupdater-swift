import Core
import Foundation
import Services

private let log = AppLogger.make(category: "chrome-menu")

/// Menu-bar dispatch for chrome commands (ADR 0010): the menu renders the
/// projection's descriptors, and dispatch revalidates against the current
/// projection before performing the typed operation. Manual runs route
/// through ActivityCommands so menu outcomes are the same typed results
/// the activity surface renders; recovery resume stays on the direct
/// chrome-gated preflight (ADR 0006) — an activity-descriptor double
/// gate could reject against a surface the user is not looking at.
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
        let result = await makeMenuActivityCommands().handle(.runManually())
        log.info("Menu run outcome: \(result.status.rawValue, privacy: .public)")
    }

    /// ActivityCommands wired with backend closures only. The reload
    /// closures are no-ops on purpose: the load chain is host-owned
    /// (slice-10 D5) and today's direct menu path queues no reload
    /// either — behavior parity, typed outcomes gained.
    func makeMenuActivityCommands() -> ActivityCommands {
        ActivityCommands(
            isRunOrchestratorAvailable: { [weak self] in self?.runOrchestrator != nil },
            submitManualRun: { [weak self] in
                guard let self else { throw AppDependencyServiceError.runOrchestratorUnavailable }
                return try await self.submitManualRun()
            },
            releaseQueuedWrite: { [weak self] in
                await self?.runOrchestrator?.releaseQueuedWrite() ?? .empty
            },
            dismissRecoveryWork: { [weak self] runID, itemIDs, reason, isIndividual in
                guard let self else { throw AppDependencyServiceError.runOrchestratorUnavailable }
                try await self.dismissRecoveryWork(
                    id: runID,
                    itemIDs: itemIDs,
                    reason: reason,
                    isIndividual: isIndividual
                )
            },
            queueManualReload: { _ in
                // Host-owned load chain (D5); nothing to queue headless.
            },
            reloadLibrary: { _ in
                // Host-owned load chain (D5).
            },
            refreshActivityProjection: { [weak self] in
                await self?.republishActivityProjection() ?? .empty()
            },
            runRecoveryPreflight: { [weak self] runID in
                await self?.runRecoveryPreflight(runID: runID)
                    ?? .blocked(runID: runID, reason: .storeUnavailable)
            },
            currentFixPlanID: { nil }
        )
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
            await refreshReportsProjection()
        }
    }
}
