// UpdateConfigSection.swift -- Mode picker, scope preview, options, confidence, dry-run toggle.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Update Config Section

struct UpdateConfigSection: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]
    let testArtists: [String]
    let credentialIssue: DiscogsCredentialIssue?
    let isLibraryReadyForUpdates: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                modeSelector
                scopePreviewCard
                if let credentialWarningMessage {
                    credentialWarningCard(credentialWarningMessage)
                }
                maintenanceStatusCard
                if viewModel.mode == .releaseYearRestore {
                    releaseYearRestoreSection
                } else if viewModel.mode != .pendingVerification {
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
        .onChange(of: viewModel.releaseYearRestoreThreshold) { _, _ in
            viewModel.computeScopePreview(tracks: tracks)
        }
    }

    var credentialWarningMessage: String? {
        guard let credentialIssue else { return nil }
        return "\(credentialIssue.message) Year lookup may be slower and less complete until this is fixed."
    }
}

extension UpdateConfigSection {
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
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                scopeChip(scopeTitle, systemImage: viewModel.mode.icon, tint: Ayu.accent)

                if isTestArtistScopeActive {
                    scopeChip(
                        testArtistScopeTitle,
                        systemImage: "person.crop.circle.badge.checkmark",
                        tint: Ayu.warning
                    )
                }

                Spacer(minLength: Spacing.md)
            }

            HStack(spacing: Spacing.lg) {
                scopeMetric(
                    value: viewModel.scopeTrackCount.formatted(),
                    label: "effective tracks"
                )

                Divider()
                    .frame(height: 32)

                scopeMetric(
                    value: viewModel.scopeArtistCount.formatted(),
                    label: "effective artists"
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

            if isTestArtistScopeActive {
                Text("Full Library and selected updates are limited to configured test artists.")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
    }

    private func credentialWarningCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Ayu.warning)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("API provider needs attention")
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)
                Text(message)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(Ayu.warning.opacity(0.12), in: .rect(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(Ayu.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private var scopeTitle: String {
        switch viewModel.mode {
        case .fullLibrary:
            "Full Library - effective scope"
        case .selectedTracks:
            "Selected Tracks"
        case .smartFilter:
            "Smart Filter - \(viewModel.smartFilterType.rawValue)"
        case .pendingVerification:
            "Pending Verification"
        case .releaseYearRestore:
            "Restore Years"
        }
    }

    private var isTestArtistScopeActive: Bool {
        !normalizedTestArtists.isEmpty
    }

    private var normalizedTestArtists: [String] {
        ArtistAllowList.normalized(testArtists)
    }

    private var testArtistScopeTitle: String {
        if normalizedTestArtists.count == 1, let artist = normalizedTestArtists.first {
            return "Test Artist: \(artist)"
        }
        return "Test Artists: \(normalizedTestArtists.count)"
    }

    private func scopeChip(
        _ title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.12), in: .capsule)
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

    // MARK: - Maintenance Status

    @ViewBuilder
    private var maintenanceStatusCard: some View {
        if let result = viewModel.maintenancePreflightResult,
           result.hasVisibleMaintenanceStatus,
           viewModel.mode != .releaseYearRestore {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let databaseVerification = result.databaseVerification,
                   databaseVerification.removedCount > 0 {
                    maintenanceStatusRow(
                        icon: "checkmark.circle.fill",
                        title: "Database cleaned",
                        detail: "\(databaseVerification.removedCount) stale tracks removed from the local database.",
                        tint: Ayu.success
                    )
                }

                if let error = result.databaseVerificationError {
                    maintenanceStatusRow(
                        icon: "exclamationmark.triangle.fill",
                        title: "Database check skipped",
                        detail: error,
                        tint: Ayu.warning
                    )
                }

                if result.isPendingVerificationDue,
                   viewModel.mode != .pendingVerification {
                    HStack(spacing: Spacing.md) {
                        maintenanceStatusRow(
                            icon: "clock.badge.exclamationmark.fill",
                            title: "Pending verification due",
                            detail: "Review queued albums before writing release years.",
                            tint: Ayu.warning
                        )

                        Spacer(minLength: Spacing.md)

                        Button {
                            viewModel.mode = .pendingVerification
                            viewModel.computeScopePreview(tracks: tracks)
                        } label: {
                            Label("Review", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(Spacing.md)
            .background(Ayu.bgSecondary, in: .rect(cornerRadius: Radius.sm))
        }
    }

    private func maintenanceStatusRow(
        icon: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.subheadline)
                    .foregroundStyle(Ayu.fgPrimary)
                Text(detail)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    // MARK: - Release Year Restore

    private var releaseYearRestoreSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Stepper(value: $viewModel.releaseYearRestoreThreshold, in: 0 ... 100) {
                LabeledContent(
                    "Restore when gap exceeds",
                    value: "\(viewModel.releaseYearRestoreThreshold)y"
                )
            }
            Text("Writes Music.app year from the track release year field.")
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
        .disabled(isStartDisabled)
    }

    private var startButtonTitle: String {
        guard isLibraryReadyForUpdates else {
            return "Preparing Library"
        }

        return switch viewModel.mode {
        case .fullLibrary:
            "Start Processing"
        case .pendingVerification:
            "Verify Pending"
        case .releaseYearRestore:
            "Restore Years"
        case .selectedTracks, .smartFilter:
            "Start Preview"
        }
    }

    private var isStartDisabled: Bool {
        !isLibraryReadyForUpdates
            || !viewModel.canStart
            || !viewModel.hasEnabledOperation
            || !viewModel.hasRunnableScope
    }
}

extension MaintenancePreflightResult {
    fileprivate var hasVisibleMaintenanceStatus: Bool {
        if isPendingVerificationDue { return true }
        if databaseVerificationError != nil { return true }
        return (databaseVerification?.removedCount ?? 0) > 0
    }
}
