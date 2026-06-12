// UpdateConfigSection.swift -- Mode picker, scope preview, options, confidence, dry-run toggle.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Config Section

struct UpdateConfigSection: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                modeSelector
                scopePreviewCard
                if viewModel.mode != .pendingVerification {
                    optionsCard
                    confidenceSection
                }
                startButton
            }
            .padding(Spacing.xl)
        }
        .onAppear { viewModel.computeScopePreview(tracks: tracks) }
        .onChange(of: viewModel.mode) { _, _ in
            viewModel.computeScopePreview(tracks: tracks)
        }
    }

    // MARK: - Mode Selector

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

            if viewModel.mode == .smartFilter {
                smartFilterPicker
            }
        }
        .disabled(viewModel.isProcessing)
    }

    private var smartFilterPicker: some View {
        Picker("Filter type", selection: $viewModel.smartFilterType) {
            ForEach(SmartFilterType.allCases) { filterType in
                Text(filterType.rawValue).tag(filterType)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.smartFilterType) { _, _ in
            viewModel.computeScopePreview(tracks: tracks)
        }
    }

    // MARK: - Scope Preview

    private var scopePreviewCard: some View {
        HStack(spacing: Spacing.lg) {
            scopeMetric(
                value: viewModel.scopeTrackCount.formatted(),
                label: "tracks"
            )

            Divider()
                .frame(height: 32)

            scopeMetric(
                value: viewModel.scopeArtistCount.formatted(),
                label: "artists"
            )

            if viewModel.mode == .fullLibrary, let lastDate = mostRecentDateAdded {
                Divider()
                    .frame(height: 32)
                scopeMetric(
                    value: lastDate.formatted(.relative(presentation: .named)),
                    label: "last scan"
                )
            }

            if viewModel.mode == .pendingVerification {
                Divider()
                    .frame(height: 32)
                scopeMetric(
                    value: viewModel.pendingDueAlbumCount.formatted(),
                    label: "due"
                )
                if viewModel.pendingSkippedAlbumCount > 0 {
                    Divider()
                        .frame(height: 32)
                    scopeMetric(
                        value: viewModel.pendingSkippedAlbumCount.formatted(),
                        label: "waiting"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
    }

    private func scopeMetric(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(AppFont.subheadline)
                .monospacedDigit()
                .foregroundStyle(Ayu.fgPrimary)
            Text(label)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
        }
    }

    private var mostRecentDateAdded: Date? {
        tracks.compactMap(\.dateAdded).max()
    }

    // MARK: - Options Card

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Update Options")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            VStack(spacing: Spacing.sm) {
                Toggle("Update Genre", isOn: $viewModel.updateGenre)
                Toggle("Update Year", isOn: $viewModel.updateYear)
                Toggle("Clean Track Names", isOn: $viewModel.cleanTrackNames)
                Toggle("Clean Album Names", isOn: $viewModel.cleanAlbumNames)

                Divider()

                dryRunToggle
            }
            .padding(Spacing.md)
            .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
        }
        .disabled(viewModel.isProcessing)
    }

    private var dryRunToggle: some View {
        HStack {
            Toggle("Preview only (dry run)", isOn: $viewModel.previewOnly)
            if !viewModel.previewOnly {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Ayu.warning)
                    .help("Live writes are enabled. Changes will be written to Music.app.")
            }
        }
        .tint(viewModel.previewOnly ? Ayu.accent : Ayu.warning)
    }

    // MARK: - Confidence Slider

    private var confidenceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Minimum confidence: \(viewModel.confidencePercentage)%")
                .font(AppFont.subheadline)
                .foregroundStyle(Ayu.fgPrimary)
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
        .disabled(viewModel.isProcessing)
    }

    // MARK: - Start Button

    private var startButton: some View {
        Button {
            viewModel.start(tracks: tracks)
        } label: {
            Label(
                startButtonTitle,
                systemImage: "play.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Ayu.accent)
        .controlSize(.large)
        .disabled(!viewModel.canStart || !viewModel.hasEnabledOperation)
    }

    private var startButtonTitle: String {
        switch viewModel.mode {
        case .fullLibrary:
            "Start Processing"
        case .pendingVerification:
            "Verify Pending"
        case .selectedTracks, .smartFilter:
            "Start Preview"
        }
    }
}
