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
    /// launch completion and after every runtime configuration apply.
    /// Identical arming inputs keep the live loop — otherwise every
    /// settings edit would reset the schedule and, with a stale
    /// tracker, fire an immediate observation per edit.
    func applyAutomationStrategy() async {
        let strategy = config.runtime.automationStrategy
        let hasGate = featureGate?.canAccess(.autoSync) == true
        applyScheduleSource(strategy: strategy, hasGate: hasGate)
        applyWatchSource(strategy: strategy, hasGate: hasGate)
        isAutoSyncRunning = automationScheduleTask != nil || automationWatchTask != nil
    }

    private func applyScheduleSource(strategy: AutomationStrategy, hasGate: Bool) {
        let interval = TimeInterval(max(1, config.runtime.incrementalIntervalMinutes)) * 60
        let isEligible = (strategy == .scheduled || strategy == .hybrid) && hasGate

        if isEligible, automationScheduleTask != nil, armedScheduleInterval == interval {
            return
        }

        automationScheduleTask?.cancel()
        automationScheduleTask = nil
        armedScheduleInterval = nil

        guard isEligible else { return }

        armedScheduleInterval = interval
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

    /// Python launchd WatchPaths parity, in-process: one observation per
    /// library mutation, throttled to the plist's 300 s window. An
    /// unavailable source (sandbox) degrades honestly to schedule-only.
    private func applyWatchSource(strategy: AutomationStrategy, hasGate: Bool) {
        let source = resolvedLibraryChangeSource()
        let path = config.paths.musicLibraryPath
        let isEligible = (strategy == .libraryChange || strategy == .hybrid)
            && hasGate
            && source?.isAvailable == true

        if isEligible, automationWatchTask != nil, armedWatchPath == path {
            return
        }

        automationWatchTask?.cancel()
        automationWatchTask = nil
        armedWatchPath = nil

        guard isEligible, let source else {
            if strategy == .libraryChange || strategy == .hybrid, hasGate {
                log.info("Watch source unavailable; degrading to the schedule source")
            }
            return
        }

        armedWatchPath = path
        automationWatchTask = Task { [weak self] in
            for await _ in source.events() {
                if Task.isCancelled {
                    break
                }
                guard let self else { break }
                await self.submitWatchObservation()
            }
        }
        log.info("Watch source armed for \(strategy.rawValue, privacy: .public)")
    }

    /// The source is built once from the configured path; tests install
    /// their own before arming.
    private func resolvedLibraryChangeSource() -> (any LibraryChangeSource)? {
        if let libraryChangeSource {
            return libraryChangeSource
        }
        let watcher = MusicLibraryFileWatcher(libraryPath: config.paths.musicLibraryPath)
        libraryChangeSource = watcher
        return watcher
    }

    /// Pure schedule math (Python can_run_incremental parity): a missing
    /// anchor fires immediately (fail open); an overdue anchor fires
    /// immediately; otherwise wait out the remainder.
    static func scheduleDelay(anchor: Date?, now: Date, interval: TimeInterval) -> TimeInterval {
        guard let anchor else { return 0 }
        let elapsed = now.timeIntervalSince(anchor)
        return elapsed >= interval ? 0 : interval - elapsed
    }

    /// The anchor is the LATER of the durable tracker timestamp and the
    /// in-memory last tick: observations never advance the tracker, so
    /// without the tick anchor every re-arm after the first tick would
    /// fire immediately.
    private func initialScheduleDelay(interval: TimeInterval) async -> TimeInterval {
        let trackerLastRun = await incrementalRunTracker?.getLastRunTimestamp()
        let anchor = [trackerLastRun, lastScheduledTickAt].compactMap(\.self).max()
        return Self.scheduleDelay(anchor: anchor, now: Date(), interval: interval)
    }

    /// One scheduled tick = one observation submitted through the
    /// orchestrator; the arbiter absorbs or queues it against any active
    /// run (ADR 0003 priorities). The gate is re-checked per tick so a
    /// lapsed subscription disarms mid-session instead of ticking on.
    func submitScheduledObservation() async {
        guard featureGate?.canAccess(.autoSync) == true else {
            automationScheduleTask?.cancel()
            automationScheduleTask = nil
            armedScheduleInterval = nil
            isAutoSyncRunning = false
            log.info("Automation gate lapsed; schedule source disarmed")
            return
        }
        guard let runOrchestrator else { return }
        lastScheduledTickAt = Date()
        let request = await RunRequest.observation(
            trigger: .backgroundSync,
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: currentKnownTrackCount()
        )
        let result = await runOrchestrator.submit(request)
        log.info("Scheduled observation finished as \(String(describing: result.lifecycle?.state), privacy: .public)")
    }

    /// Python launchd ThrottleInterval (300 s): mutation bursts coalesce
    /// into one observation; the gate is re-checked per event.
    static let watchThrottleInterval: TimeInterval = 300

    func submitWatchObservation() async {
        guard featureGate?.canAccess(.autoSync) == true else {
            automationWatchTask?.cancel()
            automationWatchTask = nil
            armedWatchPath = nil
            isAutoSyncRunning = automationScheduleTask != nil
            log.info("Automation gate lapsed; watch source disarmed")
            return
        }
        if let lastWatchTickAt,
           Date().timeIntervalSince(lastWatchTickAt) < Self.watchThrottleInterval {
            return
        }
        guard let runOrchestrator else { return }
        lastWatchTickAt = Date()
        let request = await RunRequest.observation(
            trigger: .fileSystemEvent,
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: currentKnownTrackCount()
        )
        let result = await runOrchestrator.submit(request)
        log.info("Watch observation finished as \(String(describing: result.lifecycle?.state), privacy: .public)")
    }
}
