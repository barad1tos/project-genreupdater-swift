import Core
import Foundation
import Services

private let log = AppLogger.make(category: "automation-runtime")

/// The in-process automation runtime (ADR 0003, slice 13): trigger
/// sources armed by the persisted strategy submit REAL runs through the
/// orchestrator — records, arbitration, coalescing, and chrome status
/// come from the canonical pipeline, never a second implementation.
/// The always-on system agent (windowless wake) is slice-14 territory;
/// until then the sources live for the app process only.
extension AppDependencies {
    /// Re-arms trigger sources from the persisted strategy. Called at
    /// initialize and after every runtime configuration apply, so a
    /// strategy or interval change takes effect immediately.
    func applyAutomationStrategy() async {
        automationScheduleTask?.cancel()
        automationScheduleTask = nil

        let strategy = config.runtime.automationStrategy
        guard strategy == .scheduled || strategy == .hybrid else { return }
        guard let featureGate, await featureGate.canAccess(.autoSync) else {
            log.info("Automation strategy \(strategy.rawValue, privacy: .public) requires Pro; staying manual")
            return
        }

        let interval = TimeInterval(max(1, config.runtime.incrementalIntervalMinutes)) * 60
        automationScheduleTask = Task { [weak self] in
            var delay = await self?.initialScheduleDelay(interval: interval) ?? interval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }
                guard let self else { break }
                await self.submitScheduledObservation()
                delay = interval
            }
        }
        log
            .info(
                "Schedule source armed at \(Int(interval), privacy: .public)s for \(strategy.rawValue, privacy: .public)"
            )
    }

    /// Python parity (can_run_incremental): the first tick fires
    /// immediately when the persisted last-run timestamp is stale or
    /// unreadable (fail open); otherwise it waits out the remainder.
    private func initialScheduleDelay(interval: TimeInterval) async -> TimeInterval {
        guard let lastRun = await incrementalRunTracker?.getLastRunTimestamp() else { return 0 }
        let elapsed = Date().timeIntervalSince(lastRun)
        guard elapsed < interval else { return 0 }
        return interval - elapsed
    }

    /// One scheduled tick = one observation submitted through the
    /// orchestrator. The arbiter ranks .backgroundSync below every
    /// manual intent, so a tick during an active run queues or is
    /// covered — never displaces user work (ADR 0003 priorities).
    func submitScheduledObservation() async {
        guard let runOrchestrator else { return }
        let request = await RunRequest.observation(
            trigger: .backgroundSync,
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: currentKnownTrackCount()
        )
        let result = await runOrchestrator.submit(request)
        log.info("Scheduled observation finished as \(String(describing: result.lifecycle?.state), privacy: .public)")
    }
}
