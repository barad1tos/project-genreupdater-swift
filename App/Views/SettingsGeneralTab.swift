// SettingsGeneralTab.swift — general workflow and subscription settings.

import Core
import Foundation
import SharedUI
import SwiftUI

// MARK: - General Tab

struct GeneralTab: View {
    @Environment(AppDependencies.self) private var dependencies
    @AppStorage("defaultUpdateBehavior") private var updateBehavior: String = UpdateBehavior.both.rawValue
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            Section("Update Behavior") {
                Picker("Default update behavior", selection: $updateBehavior) {
                    ForEach(UpdateBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show notifications on completion", isOn: $showNotifications)
                Toggle("Preview only by default", isOn: configBinding(dependencies, \.runtime.dryRun))
            }

            confidenceSection
            fallbackSection
            yearValidationSection
            workflowSection
            MusicAppScriptingSection(dependencies: dependencies)
            genreUpdatesSection
            subscriptionSection
        }
        .formStyle(.grouped)
        .padding()
    }

    private var confidenceSection: some View {
        Section("Confidence Thresholds") {
            let confidenceBinding = Binding<Double>(
                get: { Double(dependencies.config.yearRetrieval.logic.minConfidenceForNewYear) },
                set: { newValue in
                    dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = newValue
                    saveConfig()
                }
            )

            VStack(alignment: .leading) {
                Text("Minimum confidence: \(Int(dependencies.config.yearRetrieval.logic.minConfidenceForNewYear))%")
                Slider(value: confidenceBinding, in: 0 ... 100, step: 5)
            }

            let definitiveBinding = Binding<Double>(
                get: { Double(dependencies.config.yearRetrieval.logic.definitiveScoreThreshold) },
                set: { newValue in
                    dependencies.config.yearRetrieval.logic.definitiveScoreThreshold = Int(newValue)
                    saveConfig()
                }
            )

            VStack(alignment: .leading) {
                Text("Definitive score threshold: \(dependencies.config.yearRetrieval.logic.definitiveScoreThreshold)")
                Slider(value: definitiveBinding, in: 0 ... 100, step: 5)
            }

            Stepper(value: configBinding(dependencies, \.yearRetrieval.logic.definitiveScoreDiff), in: 0 ... 100) {
                LabeledContent(
                    "Definitive score gap",
                    value: "\(dependencies.config.yearRetrieval.logic.definitiveScoreDiff)"
                )
            }
        }
    }

    private var fallbackSection: some View {
        Section("Year Fallback") {
            Toggle("Use fallback rules", isOn: configBinding(dependencies, \.yearRetrieval.fallback.enabled))

            Group {
                Stepper(
                    value: configBinding(dependencies, \.yearRetrieval.fallback.yearDifferenceThreshold),
                    in: 0 ... 50
                ) {
                    LabeledContent(
                        "Keep existing within",
                        value: "\(dependencies.config.yearRetrieval.fallback.yearDifferenceThreshold)y"
                    )
                }

                VStack(alignment: .leading) {
                    Text("Trust API score: \(Int(dependencies.config.yearRetrieval.fallback.trustAPIScoreThreshold))%")
                    Slider(
                        value: configBinding(dependencies, \.yearRetrieval.fallback.trustAPIScoreThreshold),
                        in: 0 ... 100,
                        step: 5
                    )
                }

                Stepper(
                    value: configBinding(dependencies, \.yearRetrieval.fallback.maxVerificationAttempts),
                    in: 1 ... 20
                ) {
                    LabeledContent(
                        "Max verification attempts",
                        value: "\(dependencies.config.yearRetrieval.fallback.maxVerificationAttempts)"
                    )
                }
            }
            .disabled(!dependencies.config.yearRetrieval.fallback.enabled)
        }
    }

    private var yearValidationSection: some View {
        Section("Year Validation") {
            Stepper(value: configBinding(dependencies, \.yearRetrieval.logic.minValidYear), in: 1000 ... 2100) {
                LabeledContent(
                    "Minimum valid year",
                    value: "\(dependencies.config.yearRetrieval.logic.minValidYear)"
                )
            }

            Stepper(value: configBinding(dependencies, \.yearRetrieval.logic.absurdYearThreshold), in: 1000 ... 2100) {
                LabeledContent(
                    "Absurd year threshold",
                    value: "\(dependencies.config.yearRetrieval.logic.absurdYearThreshold)"
                )
            }

            Stepper(value: configBinding(dependencies, \.yearRetrieval.logic.suspicionThresholdYears), in: 0 ... 100) {
                LabeledContent(
                    "Suspicion gap",
                    value: "\(dependencies.config.yearRetrieval.logic.suspicionThresholdYears)y"
                )
            }
        }
    }

    private var workflowSection: some View {
        Section("Workflow") {
            Stepper(value: configBinding(dependencies, \.processing.batchSize), in: 1 ... 500) {
                LabeledContent("Processing batch size", value: "\(dependencies.config.processing.batchSize)")
            }

            Stepper(
                value: configBinding(dependencies, \.processing.delayBetweenBatches),
                in: 0 ... 120,
                step: 1
            ) {
                LabeledContent("Batch delay", value: "\(Int(dependencies.config.processing.delayBetweenBatches))s")
            }

            Toggle("Adaptive delay", isOn: configBinding(dependencies, \.processing.adaptiveDelay))

            Stepper(value: configBinding(dependencies, \.runtime.incrementalIntervalMinutes), in: 1 ... 1440) {
                LabeledContent(
                    "Incremental interval",
                    value: "\(dependencies.config.runtime.incrementalIntervalMinutes)m"
                )
            }

            Stepper(value: configBinding(dependencies, \.processing.pendingVerificationIntervalDays), in: 0 ... 365) {
                LabeledContent(
                    "Pending verification",
                    value: "\(dependencies.config.processing.pendingVerificationIntervalDays)d"
                )
            }

            Toggle("Skip prereleases", isOn: configBinding(dependencies, \.processing.skipPrerelease))

            Picker("Prerelease handling", selection: configBinding(dependencies, \.processing.prereleaseHandling)) {
                ForEach(PrereleaseHandling.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Stepper(value: configBinding(dependencies, \.processing.futureYearThreshold), in: 0 ... 10) {
                LabeledContent("Future year threshold", value: "\(dependencies.config.processing.futureYearThreshold)y")
            }

            Stepper(value: configBinding(dependencies, \.processing.prereleaseRecheckDays), in: 0 ... 365) {
                LabeledContent("Prerelease recheck", value: "\(dependencies.config.processing.prereleaseRecheckDays)d")
            }

            Stepper(value: configBinding(dependencies, \.processing.releaseYearRestoreThreshold), in: 0 ... 100) {
                LabeledContent(
                    "Release-year restore gap",
                    value: "\(dependencies.config.processing.releaseYearRestoreThreshold)y"
                )
            }
        }
    }

    private var genreUpdatesSection: some View {
        Section("Genre Updates") {
            Stepper(value: configBinding(dependencies, \.genreUpdate.batchSize), in: 1 ... 500) {
                LabeledContent("Batch size", value: "\(dependencies.config.genreUpdate.batchSize)")
            }

            Stepper(value: configBinding(dependencies, \.genreUpdate.concurrentLimit), in: 1 ... 20) {
                LabeledContent("Concurrent limit", value: "\(dependencies.config.genreUpdate.concurrentLimit)")
            }

            Toggle("Override existing genres", isOn: configBinding(dependencies, \.genreUpdate.overrideExisting))

            Toggle("Experimental batch updates", isOn: configBinding(dependencies, \.experimental.batchUpdatesEnabled))

            Stepper(value: configBinding(dependencies, \.experimental.maxBatchSize), in: 1 ... 50) {
                LabeledContent(
                    "Experimental max batch",
                    value: "\(dependencies.config.experimental.maxBatchSize)"
                )
            }
            .disabled(!dependencies.config.experimental.batchUpdatesEnabled)
        }
    }

    private var subscriptionSection: some View {
        Section("Subscription") {
            if let gate = dependencies.featureGate {
                HStack {
                    Text("Current plan")
                    Spacer()
                    TierBadge(tier: gate.currentTier)
                }
            }

            NavigationLink("Manage Subscription") {
                SubscriptionView()
            }
        }
    }

    private func saveConfig() {
        saveConfiguration(dependencies)
    }
}

private struct MusicAppScriptingSection: View {
    let dependencies: AppDependencies

    var body: some View {
        Section("Music App Scripting") {
            AppleScriptConcurrencySettings(dependencies: dependencies)
            AppleScriptBatchFetchSettings(dependencies: dependencies)
            AppleScriptRateLimitSettings(dependencies: dependencies)
            AppleScriptRetrySettings(dependencies: dependencies)
            AppleScriptTimeoutSettings(dependencies: dependencies)
        }
    }
}

private struct AppleScriptConcurrencySettings: View {
    let dependencies: AppDependencies

    var body: some View {
        Stepper(value: configBinding(dependencies, \.applescript.concurrency), in: 1 ... 10) {
            LabeledContent(
                "Concurrent AppleScript calls",
                value: "\(dependencies.config.applescript.concurrency)"
            )
        }
    }
}

private struct AppleScriptBatchFetchSettings: View {
    let dependencies: AppDependencies

    var body: some View {
        Stepper(
            value: configBinding(dependencies, \.applescript.batchProcessing.idsBatchSize),
            in: 1 ... 5000,
            step: 50
        ) {
            LabeledContent(
                "ID fetch batch size",
                value: "\(dependencies.config.applescript.batchProcessing.idsBatchSize)"
            )
        }
    }
}

private struct AppleScriptRateLimitSettings: View {
    let dependencies: AppDependencies

    var body: some View {
        Toggle("Rate limit AppleScript calls", isOn: configBinding(dependencies, \.applescript.rateLimit.enabled))

        Group {
            Stepper(value: configBinding(dependencies, \.applescript.rateLimit.requestsPerWindow), in: 1 ... 60) {
                LabeledContent(
                    "Requests per window",
                    value: "\(dependencies.config.applescript.rateLimit.requestsPerWindow)"
                )
            }

            Stepper(
                value: configBinding(dependencies, \.applescript.rateLimit.windowSizeSeconds),
                in: 0.1 ... 60,
                step: 0.1
            ) {
                LabeledContent(
                    "Window size",
                    value: String(format: "%.1fs", dependencies.config.applescript.rateLimit.windowSizeSeconds)
                )
            }
        }
        .disabled(!dependencies.config.applescript.rateLimit.enabled)
    }
}

private struct AppleScriptRetrySettings: View {
    let dependencies: AppDependencies

    var body: some View {
        Stepper(value: configBinding(dependencies, \.applescript.retry.maxRetries), in: 0 ... 10) {
            LabeledContent("Retry attempts", value: "\(dependencies.config.applescript.retry.maxRetries)")
        }

        Group {
            Stepper(
                value: configBinding(dependencies, \.applescript.retry.baseDelaySeconds),
                in: 0 ... 30,
                step: 0.5
            ) {
                LabeledContent(
                    "Retry base delay",
                    value: String(format: "%.1fs", dependencies.config.applescript.retry.baseDelaySeconds)
                )
            }

            Stepper(
                value: configBinding(dependencies, \.applescript.retry.maxDelaySeconds),
                in: 0 ... 120,
                step: 0.5
            ) {
                LabeledContent(
                    "Retry max delay",
                    value: String(format: "%.1fs", dependencies.config.applescript.retry.maxDelaySeconds)
                )
            }

            VStack(alignment: .leading) {
                Text("Retry jitter: \(Int(dependencies.config.applescript.retry.jitterRange * 100))%")
                Slider(
                    value: configBinding(dependencies, \.applescript.retry.jitterRange),
                    in: 0 ... 1,
                    step: 0.05
                )
            }

            Stepper(
                value: configBinding(dependencies, \.applescript.retry.operationTimeoutSeconds),
                in: 0 ... 600,
                step: 5
            ) {
                LabeledContent(
                    "Retry operation timeout",
                    value: String(format: "%.0fs", dependencies.config.applescript.retry.operationTimeoutSeconds)
                )
            }
        }
        .disabled(dependencies.config.applescript.retry.maxRetries == 0)
    }
}

private struct AppleScriptTimeoutSettings: View {
    let dependencies: AppDependencies

    var body: some View {
        Stepper(value: timeoutSecondsBinding(\.defaultTimeout), in: 60 ... 7200, step: 60) {
            LabeledContent(
                "Default timeout",
                value: timeoutDisplay(dependencies.config.applescript.timeouts.defaultTimeout)
            )
        }

        Stepper(value: timeoutSecondsBinding(\.fullLibraryFetch), in: 300 ... 7200, step: 300) {
            LabeledContent(
                "Full library fetch",
                value: timeoutDisplay(dependencies.config.applescript.timeouts.fullLibraryFetch)
            )
        }

        Stepper(value: timeoutSecondsBinding(\.singleArtistFetch), in: 60 ... 3600, step: 60) {
            LabeledContent(
                "Single artist fetch",
                value: timeoutDisplay(dependencies.config.applescript.timeouts.singleArtistFetch)
            )
        }

        Stepper(value: timeoutSecondsBinding(\.idsBatchFetch), in: 30 ... 1800, step: 30) {
            LabeledContent(
                "ID batch fetch timeout",
                value: timeoutDisplay(dependencies.config.applescript.timeouts.idsBatchFetch)
            )
        }

        Stepper(value: timeoutSecondsBinding(\.batchUpdate), in: 60 ... 7200, step: 60) {
            LabeledContent(
                "Batch update timeout",
                value: timeoutDisplay(dependencies.config.applescript.timeouts.batchUpdate)
            )
        }
    }

    private func timeoutSecondsBinding(_ keyPath: WritableKeyPath<AppleScriptTimeouts, Duration>) -> Binding<Int> {
        Binding(
            get: {
                max(1, Int(dependencies.config.applescript.timeouts[keyPath: keyPath].timeInterval))
            },
            set: { newValue in
                dependencies.config.applescript.timeouts[keyPath: keyPath] = .seconds(max(1, newValue))
                saveConfiguration(dependencies)
            }
        )
    }

    private func timeoutDisplay(_ duration: Duration) -> String {
        let seconds = max(1, Int(duration.timeInterval))
        if seconds >= 3600, seconds.isMultiple(of: 3600) {
            return "\(seconds / 3600)h"
        }
        if seconds >= 60, seconds.isMultiple(of: 60) {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }
}
