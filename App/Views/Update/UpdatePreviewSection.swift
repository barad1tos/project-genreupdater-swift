// UpdatePreviewSection.swift -- Grouped change list with per-group Accept/Reject and ConfidenceBadge.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Update Preview Section

struct UpdatePreviewSection: View {
    @Bindable var viewModel: WorkflowViewModel

    private var groupedChanges: [ChangePreviewGroup] {
        ChangePreviewGrouping.groups(from: viewModel.proposedChanges)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            changeList
            Divider()
            actionBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("\(viewModel.proposedChanges.count) changes proposed")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)
            Spacer()
            Text("\(viewModel.acceptedCount) accepted")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .monospacedDigit()
        }
        .padding(Spacing.md)
    }

    // MARK: - Change List

    private var changeList: some View {
        List {
            ForEach(groupedChanges, id: \.key) { group in
                Section {
                    ForEach(group.changes) { change in
                        changeRow(for: change)
                            .contentShape(.rect)
                    }
                } header: {
                    groupHeader(key: group.key.displayTitle, changes: group.changes)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Group Header

    private func groupHeader(
        key: String,
        changes: [ProposedChange]
    ) -> some View {
        HStack {
            Text(key)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgSecondary)
            Spacer()
            Button("Accept") {
                acceptGroup(changes)
            }
            .font(AppFont.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Ayu.accent)
            Button("Reject") {
                rejectGroup(changes)
            }
            .font(AppFont.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Ayu.fgMuted)
        }
    }

    // MARK: - Change Row

    private func changeRow(for change: ProposedChange) -> some View {
        let index = viewModel.proposedChanges.firstIndex(where: { $0.id == change.id })
        return HStack(spacing: Spacing.sm) {
            Toggle(
                isOn: Binding(
                    get: { change.isAccepted },
                    set: { _ in
                        if let foundIndex = index {
                            viewModel.toggleChange(at: foundIndex)
                        }
                    }
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

            if !change.source.isEmpty {
                Text(change.source)
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
                    .lineLimit(1)
                    .help("Source: \(change.source)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Change Type Icon

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

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button("Back") { viewModel.reset() }
            Button("Accept All") { viewModel.acceptAll() }
            Button("Reject All") { viewModel.rejectAll() }
            Spacer()
            if viewModel.previewOnly {
                Button {
                    viewModel.enableWritesForReviewedChanges()
                } label: {
                    Label("Enable Writes", systemImage: "pencil.and.list.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(Ayu.warning)
                .disabled(viewModel.acceptedCount == 0)
            } else {
                Button {
                    viewModel.applyAccepted()
                } label: {
                    Text("Apply \(viewModel.acceptedCount) Changes")
                }
                .buttonStyle(.borderedProminent)
                .tint(Ayu.accent)
                .disabled(viewModel.acceptedCount == 0)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: - Group Actions

    private func acceptGroup(_ changes: [ProposedChange]) {
        for change in changes {
            if let index = viewModel.proposedChanges.firstIndex(where: { $0.id == change.id }),
               !viewModel.proposedChanges[index].isAccepted {
                viewModel.toggleChange(at: index)
            }
        }
    }

    private func rejectGroup(_ changes: [ProposedChange]) {
        for change in changes {
            if let index = viewModel.proposedChanges.firstIndex(where: { $0.id == change.id }),
               viewModel.proposedChanges[index].isAccepted {
                viewModel.toggleChange(at: index)
            }
        }
    }
}
