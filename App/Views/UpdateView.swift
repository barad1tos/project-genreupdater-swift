// UpdateView.swift — Sheet-based update workflow with configure, preview, and apply phases.
//
// Presents a staged flow for track metadata updates:
// 1. Configure: choose genre/year updates, confidence threshold, and preview-only mode
// 2. Processing: dry-run analysis with progress feedback
// 3a. Preview: review proposed changes, accept/reject individually or in bulk (normal mode)
// 3b. Dry-run summary: read-only report of what would change (preview-only mode)
// 4. Applying: progress while writing changes to Music.app
// 5. Done: summary of applied changes
//
// The view model (UpdateViewModel) drives all phase transitions and
// coordinates with UpdateCoordinator and ChangePreviewPipeline from Services.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Update View

struct UpdateView: View {
    @Bindable var viewModel: UpdateViewModel
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.phase {
                case .configuring:
                    configuringView
                case .processing, .applying:
                    processingView
                case .preview:
                    previewView
                case .dryRunSummary:
                    dryRunSummaryView
                case .done:
                    doneView
                }
            }
            .navigationTitle("Update Tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "An unknown error occurred.")
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - Error Binding

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.errorMessage = nil
                }
            }
        )
    }

    // MARK: - Configuring Phase

    private var configuringView: some View {
        Form {
            Section("Update Options") {
                Toggle("Update Genre", isOn: $viewModel.updateGenre)
                Toggle("Update Year", isOn: $viewModel.updateYear)
                Toggle("Force Year Lookup", isOn: $viewModel.forceYearLookup)
                    .disabled(!viewModel.updateYear)
                    .help("Bypass cached and local year shortcuts.")
                Toggle("Clean Track Names", isOn: $viewModel.cleanTrackNames)
                Toggle("Clean Album Names", isOn: $viewModel.cleanAlbumNames)
            }

            Section {
                Toggle(
                    "Preview only (dry run)",
                    isOn: $viewModel.previewOnly
                )
            } footer: {
                Text(
                    "Show a summary of what would change "
                        + "without modifying your library."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Confidence Threshold") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Minimum confidence: \(viewModel.confidencePercentage)%")
                        .font(.headline)
                    Slider(
                        value: $viewModel.minConfidence,
                        in: 0.3 ... 1.0,
                        step: 0.05
                    )
                    .accessibilityValue("\(viewModel.confidencePercentage)% confidence")
                    Text("Changes below this threshold will be excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("\(tracks.count) tracks selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Divider()
                Button {
                    viewModel.startDryRun(tracks: tracks)
                } label: {
                    Text("Start Preview")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.hasEnabledOperation)
                .padding()
            }
            .background(.bar)
        }
    }

    // MARK: - Processing Phase

    private var processingView: some View {
        VStack(spacing: Spacing.xl) {
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

            Button("Cancel", role: .cancel) {
                viewModel.cancel()
                viewModel.phase = .configuring
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview Phase

    private var previewView: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
            changeList
            Divider()
            previewActionBar
        }
    }

    private var previewHeader: some View {
        HStack {
            Text("\(viewModel.proposedChanges.count) changes proposed")
                .font(.headline)
            Spacer()
            Text("\(viewModel.acceptedCount) accepted")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var changeList: some View {
        List(viewModel.proposedChanges.indices, id: \.self) { index in
            changeRow(at: index)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func changeRow(at index: Int) -> some View {
        let change = viewModel.proposedChanges[index]
        return HStack(spacing: Spacing.sm) {
            Toggle(
                isOn: Binding(
                    get: { viewModel.proposedChanges[index].isAccepted },
                    set: { _ in viewModel.toggleChange(at: index) }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("Accept change for \(change.track.name)")
            .accessibilityHint("Double-tap to toggle this change")

            changeTypeIcon(for: change.changeType)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.track.name)
                    .font(.body)
                    .lineLimit(1)
                Text(change.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            changeValueLabel(oldValue: change.oldValue, newValue: change.newValue)

            ConfidenceBadge(confidence: Double(change.confidence) / 100.0)
        }
        .padding(.vertical, 2)
    }

    private func changeTypeIcon(for changeType: ChangeType) -> some View {
        Group {
            switch changeType {
            case .genreUpdate:
                Image(systemName: "tag.fill")
                    .foregroundStyle(.purple)
            case .yearUpdate, .yearRevert:
                Image(systemName: "calendar")
                    .foregroundStyle(.blue)
            default:
                Image(systemName: "pencil")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 20)
        .accessibilityHidden(true)
    }

    private func changeValueLabel(
        oldValue: String?,
        newValue: String?
    ) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(oldValue ?? "none")
                .foregroundStyle(.secondary)
                .strikethrough()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(newValue ?? "none")
                .foregroundStyle(.primary)
                .bold()
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "from \(oldValue ?? "none") to \(newValue ?? "none")"
        )
    }

    private var previewActionBar: some View {
        HStack {
            Button("Accept All") {
                viewModel.acceptAll()
            }

            Button("Reject All") {
                viewModel.rejectAll()
            }

            Spacer()

            Button {
                viewModel.applyAccepted()
            } label: {
                Text("Apply \(viewModel.acceptedCount) Changes")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.acceptedCount == 0)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Dry Run Summary Phase

    private var dryRunSummaryView: some View {
        DryRunSummaryView(
            report: viewModel.dryRunReport
        ) {
            viewModel.reset()
            dismiss()
        }
    }

    // MARK: - Done Phase

    private var doneView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text("Update Complete")
                .font(.title2)
                .bold()

            if let result = viewModel.result {
                resultSummary(for: result)
            }

            Spacer()

            Button("Done") {
                viewModel.reset()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultSummary(for result: BatchUpdateResult) -> some View {
        VStack(spacing: Spacing.xs) {
            Text("\(result.entries.count) tracks updated successfully")
                .font(.body)

            if !result.failedTrackIDs.isEmpty {
                Text("\(result.failedTrackCount) tracks failed")
                    .font(.body)
                    .foregroundStyle(.red)
            }

            if result.hasPartialFailures {
                Text("Some changes could not be applied. Check the tracks and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }
}

// Previews omitted: UpdateViewModel requires UpdateCoordinator and
// ChangePreviewPipeline which depend on the full service graph.
// Use the app's debug build for visual testing.
