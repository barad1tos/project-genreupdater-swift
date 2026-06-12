// SettingsGeneralTab.swift — general workflow and subscription settings.

import Core
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
            workflowSection
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
