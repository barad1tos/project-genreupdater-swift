// UpdateWorkflowView.swift -- Thin router composing Update sub-views by phase.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Workflow View

struct UpdateWorkflowView: View {
    @Bindable var viewModel: WorkflowViewModel
    let tracks: [Track]
    let testArtists: [String]
    let credentialIssue: DiscogsCredentialIssue?
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
                    credentialIssue: credentialIssue
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
            UpdatePreviewSection(viewModel: viewModel)
        case .applying:
            UpdateStreamingSection(
                viewModel: viewModel,
                tracks: tracks,
                testArtists: testArtists
            )
        case .done:
            UpdateDoneSection(viewModel: viewModel)
        case .paused:
            pausedView
        case let .error(message):
            errorView(message: message)
        }
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
