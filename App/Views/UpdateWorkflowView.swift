// UpdateWorkflowView.swift — Unified update workflow (inline, not sheet-based).

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Update Workflow View

struct UpdateWorkflowView: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]

    var body: some View {
        Group {
            switch viewModel.phase {
            case .configure:
                configureView
            case .scanning:
                scanningView
            case .review:
                reviewView
            case .applying:
                applyingView
            case .paused:
                pausedView
            case .done:
                doneView
            case let .error(message):
                errorView(message: message)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: "\(viewModel.phase)")
    }

    // MARK: - Configure Phase

    private var configureView: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                modeSelector
                optionsSection
                filterSection
                startButton
            }
            .padding(Spacing.xl)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Mode")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            Picker("Mode", selection: $viewModel.mode) {
                ForEach(WorkflowMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Update Options")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            VStack(spacing: Spacing.sm) {
                Toggle("Update Genre", isOn: $viewModel.updateGenre)
                Toggle("Update Year", isOn: $viewModel.updateYear)

                if viewModel.mode != .fullLibrary {
                    Toggle("Preview only (dry run)", isOn: $viewModel.previewOnly)
                }
            }
            .padding(Spacing.md)
            .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if viewModel.mode == .smartFilter {
                Text("Filter")
                    .font(AppFont.headline)
                    .foregroundStyle(Ayu.fgPrimary)

                Picker("Filter type", selection: $viewModel.smartFilterType) {
                    ForEach(SmartFilterType.allCases) { filterType in
                        Text(filterType.rawValue).tag(filterType)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Minimum confidence: \(viewModel.confidencePercentage)%")
                    .font(.headline)
                Slider(
                    value: $viewModel.minConfidence,
                    in: 0.3 ... 1.0,
                    step: 0.05
                )
                .tint(Ayu.accent)
                Text("Changes below this threshold will be excluded.")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            }
            .padding(Spacing.md)
            .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))

            Text("\(tracks.count.formatted()) tracks available")
                .font(.subheadline)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    private var startButton: some View {
        Button {
            viewModel.start(tracks: tracks)
        } label: {
            Label(
                viewModel.mode == .fullLibrary ? "Start Processing" : "Start Preview",
                systemImage: "play.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Ayu.accent)
        .controlSize(.large)
        .disabled(!viewModel.updateGenre && !viewModel.updateYear)
    }

    // MARK: - Scanning Phase

    private var scanningView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            ProgressRing(
                progress: viewModel.progress?.fractionComplete ?? 0,
                message: viewModel.progress?.message
            )

            if viewModel.totalCount > 0 {
                Text("\(viewModel.processedCount) of \(viewModel.totalCount)")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .contentTransition(.numericText())
            }

            HStack(spacing: Spacing.md) {
                if viewModel.mode == .fullLibrary {
                    Button("Pause") {
                        Task { await viewModel.pause() }
                    }
                    .buttonStyle(.bordered)
                }

                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Paused Phase

    private var pausedView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            Image(systemName: "pause.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Ayu.warning)

            Text("Paused")
                .font(AppFont.headline)

            Text("\(viewModel.processedCount) of \(viewModel.totalCount) processed")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)

            HStack(spacing: Spacing.md) {
                Button("Resume") {
                    Task { await viewModel.resume() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Ayu.accent)

                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review Phase

    private var reviewView: some View {
        WorkflowReviewSection(viewModel: viewModel)
    }

    // MARK: - Applying Phase

    private var applyingView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            ProgressRing(
                progress: viewModel.progress?.fractionComplete ?? 0,
                message: "Applying changes..."
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Done Phase

    private var doneView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Ayu.success)

            Text("Update Complete")
                .font(AppFont.headline)

            if let result = viewModel.result {
                VStack(spacing: Spacing.xs) {
                    Text("\(result.entries.count) tracks updated")
                        .font(.body)
                    if !result.failedTrackIDs.isEmpty {
                        Text("\(result.failedTrackIDs.count) tracks failed")
                            .foregroundStyle(Ayu.error)
                    }
                }
            } else if !viewModel.completedEntries.isEmpty {
                Text("\(viewModel.completedEntries.count) tracks updated")
                    .font(.body)
            }

            Button("Start New Update") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error Phase

    private func errorView(message: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Ayu.error)

            Text("Something went wrong")
                .font(AppFont.headline)

            Text(message)
                .font(.body)
                .foregroundStyle(Ayu.fgSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxxl)

            Button("Try Again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Review Section

private struct WorkflowReviewSection: View {
    @Bindable var viewModel: WorkflowViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            changeList
            Divider()
            actionBar
        }
    }

    private var header: some View {
        HStack {
            Text("\(viewModel.proposedChanges.count) changes proposed")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)
            Spacer()
            Text("\(viewModel.acceptedCount) accepted")
                .font(.subheadline)
                .foregroundStyle(Ayu.fgSecondary)
        }
        .padding(Spacing.md)
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

            changeTypeIcon(for: change.changeType)

            VStack(alignment: .leading, spacing: 2) {
                Text(change.track.name)
                    .font(.body)
                    .lineLimit(1)
                Text(change.track.artist)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: Spacing.xxs) {
                Text(change.oldValue ?? "none")
                    .foregroundStyle(Ayu.fgSecondary)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(Ayu.fgMuted)
                Text(change.newValue ?? "none")
                    .foregroundStyle(Ayu.fgPrimary)
                    .bold()
            }
            .font(.callout)
            .lineLimit(1)

            ConfidenceBadge(confidence: Double(change.confidence) / 100.0)
        }
        .padding(.vertical, 2)
    }

    private func changeTypeIcon(for changeType: ChangeType) -> some View {
        Group {
            switch changeType {
            case .genreUpdate:
                Image(systemName: "tag.fill").foregroundStyle(Ayu.purple)
            case .yearUpdate, .yearRevert:
                Image(systemName: "calendar").foregroundStyle(Ayu.info)
            default:
                Image(systemName: "pencil").foregroundStyle(Ayu.accent)
            }
        }
        .frame(width: 20)
    }

    private var actionBar: some View {
        HStack {
            Button("Apply All") { viewModel.acceptAll() }
            Button("Skip All") { viewModel.rejectAll() }
            Spacer()
            Button {
                viewModel.applyAccepted()
            } label: {
                Text("Apply \(viewModel.acceptedCount) Changes")
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)
            .disabled(viewModel.acceptedCount == 0)
        }
        .padding(Spacing.md)
    }
}
