// UpdateWorkflowView.swift -- Thin router composing Update sub-views by phase.

import AppKit
import Core
import DesignUI
import Foundation
import SharedUI
import SwiftUI

// MARK: - Update Workflow View

struct UpdateWorkflowView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.openSettings) private var openSettings

    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]
    let testArtists: [String]
    let reportDisplayMode: ChangeDisplayMode
    let credentialIssue: DiscogsCredentialIssue?
    let isLibraryReadyForUpdates: Bool
    @Binding var noticeMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let noticeMessage {
                noticeBanner(noticeMessage)
                Divider()
            }

            if showsConfig {
                UpdateConfigSection(
                    viewModel: viewModel,
                    tracks: tracks,
                    testArtists: testArtists,
                    credentialIssue: credentialIssue,
                    isLibraryReadyForUpdates: isLibraryReadyForUpdates
                )
                Divider()
            }

            resultsArea
                .frame(maxHeight: .infinity)
        }
        .animation(Motion.curveFast, value: "\(viewModel.phase)")
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Ayu.info)
            Text(message)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
            Spacer()
            Button {
                noticeMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ayu.fgMuted)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Ayu.bgSecondary)
    }

    // MARK: - Config Visibility

    /// Config section visible during configure and processing phases
    /// so the user can see their choices.
    private var showsConfig: Bool {
        switch viewModel.phase {
        case .configure, .scanning, .applying: true
        default: false
        }
    }

    // MARK: - Results Area

    @ViewBuilder
    private var resultsArea: some View {
        switch viewModel.phase {
        case .configure:
            Color.clear
        case .scanning:
            UpdateStreamingSection(
                viewModel: viewModel,
                tracks: tracks,
                testArtists: testArtists
            )
        case .review:
            reviewResults
        case .applying:
            UpdateStreamingSection(
                viewModel: viewModel,
                tracks: tracks,
                testArtists: testArtists
            )
        case .done:
            let report = makeDoneReport()
            UpdateResultView(
                snapshot: UpdateResultWriteAdapter.makeSnapshot(from: report),
                onPrimaryAction: { viewModel.reset() },
                onSecondaryAction: { copyReport(report) }
            )
        case .paused:
            pausedView
        case let .error(message):
            errorView(message: message)
        }
    }

    private func makeDoneReport() -> UpdateRunReport {
        viewModel.makeRunReport(displayMode: reportDisplayMode)
    }

    private func copyReport(_ report: UpdateRunReport) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.plainTextSummary, forType: .string)
    }

    private var reviewResults: some View {
        UpdateResultView(
            snapshot: UpdateResultPreviewAdapter.makeSnapshot(
                changes: viewModel.proposedChanges,
                scopeTitle: viewModel.runScopeTitle,
                hasCleaningAccess: hasCleaningAccess,
                primaryActionLabel: reviewPrimaryLabel
            ),
            onPrimaryAction: reviewPrimaryCallback,
            onSecondaryAction: { viewModel.reset() },
            onToggleChange: toggleReviewChange,
            onAcceptAll: { viewModel.acceptAll() },
            onRejectAll: { viewModel.rejectAll() },
            onAccessAction: { openSettings() },
            needsPrimaryAccess: Self.needsPrimaryAccess(previewOnly: viewModel.previewOnly)
        )
    }

    nonisolated static func needsPrimaryAccess(previewOnly: Bool) -> Bool {
        !previewOnly
    }

    private var reviewPrimaryCallback: (() -> Void)? {
        guard viewModel.acceptedCount > 0 else { return nil }
        return { reviewPrimaryAction() }
    }

    private var reviewPrimaryLabel: String {
        guard !viewModel.previewOnly else { return "Enable Writes" }
        let count = viewModel.acceptedCount
        return "Apply \(count.formatted()) \(count == 1 ? "Change" : "Changes")"
    }

    private var hasCleaningAccess: Bool {
        _ = dependencies.subscriptionService?.currentTier
        return dependencies.featureGate?.canAccess(.artistAlbumCleaning) == true
    }

    private func reviewPrimaryAction() {
        if viewModel.previewOnly {
            viewModel.enableWritesForReviewedChanges()
        } else {
            viewModel.applyAccepted()
        }
    }

    private func toggleReviewChange(_ changeID: String) {
        guard let itemID = UUID(uuidString: changeID),
              let index = viewModel.proposedChanges.firstIndex(where: { $0.id == itemID })
        else { return }
        viewModel.toggleChange(at: index)
    }

    // MARK: - Paused View

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

    // MARK: - Error View

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

            Button(viewModel.recoveryHoldID == nil ? "Try Again" : "I Verified Music.app") {
                if viewModel.recoveryHoldID == nil {
                    viewModel.reset()
                } else {
                    Task { await viewModel.clearRecoveryHold() }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Ayu.accent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
