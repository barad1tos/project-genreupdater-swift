// BatchView.swift — Batch processing UI with pause/resume/cancel controls.
//
// Wrapped in FeatureGatedView to require .batchProcessing (Week Pass+).
// Drives BatchViewModel through idle → running → paused → completed → error states,
// displaying progress via ProgressRing and a summary on completion.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Batch View

/// Batch processing interface with configuration, progress, and result phases.
///
/// Feature-gated behind `.batchProcessing` — free tier users see a paywall overlay.
struct BatchView: View {
    let tracks: [Track]
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: BatchViewModel?

    var body: some View {
        FeatureGatedView(feature: .batchProcessing) {
            if let viewModel {
                batchContent(viewModel: viewModel)
            } else {
                ProgressView("Initializing...")
            }
        }
        .navigationTitle("Batch Processing")
        .task {
            initializeViewModelIfNeeded()
        }
    }

    // MARK: - Batch Content

    @ViewBuilder
    private func batchContent(viewModel: BatchViewModel) -> some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle:
                idleView(viewModel: viewModel)
            case .running:
                runningView(viewModel: viewModel)
            case .paused:
                pausedView(viewModel: viewModel)
            case .completed:
                completedView(viewModel: viewModel)
            case .cancelled:
                cancelledView(viewModel: viewModel)
            case let .error(message):
                errorView(message: message, viewModel: viewModel)
            }
        }
    }

    // MARK: - Idle State

    private func idleView(viewModel: BatchViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return Form {
            Section("Batch Options") {
                Toggle("Update Genre", isOn: $viewModel.updateGenre)
                Toggle("Update Year", isOn: $viewModel.updateYear)
            }

            Section("Confidence Threshold") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Minimum confidence: \(viewModel.confidencePercentage)%")
                        .font(.headline)
                    Slider(
                        value: $viewModel.minConfidence,
                        in: 0.3 ... 1.0,
                        step: 0.05
                    )
                    .accessibilityValue("\(viewModel.confidencePercentage)% confidence")
                    Text("Tracks below this threshold will be skipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("\(tracks.count) tracks queued for processing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Divider()
                Button {
                    viewModel.start(tracks: tracks)
                } label: {
                    Text("Start Batch Processing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(tracks.isEmpty || (!viewModel.updateGenre && !viewModel.updateYear))
                .padding()
            }
            .background(.bar)
        }
    }

    // MARK: - Running State

    private func runningView(viewModel: BatchViewModel) -> some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressRing(
                progress: viewModel.progress?.fractionComplete ?? 0,
                message: viewModel.progress?.message
            )

            if let progress = viewModel.progress {
                Text("\(progress.current) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button("Pause") {
                    Task { await viewModel.pause() }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Double-tap to pause batch processing")

                Button("Cancel", role: .destructive) {
                    Task { await viewModel.cancel() }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Double-tap to cancel batch processing")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Paused State

    private func pausedView(viewModel: BatchViewModel) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "pause.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Paused")
                .font(.title2)
                .bold()

            if let progress = viewModel.progress {
                Text("\(progress.current) of \(progress.total) processed")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button("Resume") {
                    Task { await viewModel.resume() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Double-tap to resume batch processing")

                Button("Cancel", role: .destructive) {
                    Task { await viewModel.cancel() }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Double-tap to cancel batch processing")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Completed State

    private func completedView(viewModel: BatchViewModel) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Batch Complete")
                .font(.title2)
                .bold()

            VStack(spacing: 8) {
                Text("\(viewModel.processedCount) tracks processed")
                    .font(.body)

                Text("\(viewModel.changes.count) changes applied")
                    .font(.body)
                    .foregroundStyle(.secondary)

                if viewModel.failedCount > 0 {
                    Text("\(viewModel.failedCount) tracks failed")
                        .font(.body)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button("Process Another Batch") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cancelled State

    private func cancelledView(viewModel: BatchViewModel) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Batch Cancelled")
                .font(.title2)
                .bold()

            Text("\(viewModel.processedCount) tracks were processed before cancellation.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button("Start New Batch") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error State

    private func errorView(message: String, viewModel: BatchViewModel) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text("Processing Error")
                .font(.title2)
                .bold()

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Private Helpers

    private func initializeViewModelIfNeeded() {
        guard viewModel == nil,
              let batchProcessor = dependencies.batchProcessor,
              let updateCoordinator = dependencies.updateCoordinator
        else { return }
        viewModel = BatchViewModel(
            batchProcessor: batchProcessor,
            updateCoordinator: updateCoordinator
        )
    }
}
