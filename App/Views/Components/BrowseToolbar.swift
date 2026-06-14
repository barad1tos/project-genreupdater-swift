// BrowseToolbar.swift — Search, sort, filter chips, and bulk action bar for Browse.

import SharedUI
import SwiftUI

// MARK: - BrowseToolbar

/// Horizontal toolbar strip above the browse artist list.
///
/// Contains a search field, sort dropdown, filter chip row, and a conditional
/// bulk action bar that appears when items are multi-selected.
struct BrowseToolbar: View {
    @Bindable var viewModel: BrowseViewModel

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                searchField
                sortDropdown
            }

            filterChips

            if viewModel.hasSelection {
                bulkActionBar
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Ayu.fgMuted)

            TextField("Search artists, albums, tracks...", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgPrimary)

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Ayu.fgMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs + 2)
        .background(Ayu.bgTertiary, in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityLabel("Search library")
    }

    // MARK: - Sort Dropdown

    private var sortDropdown: some View {
        Menu {
            ForEach(BrowseSortOrder.allCases, id: \.self) { order in
                Button {
                    viewModel.sortOrder = order
                } label: {
                    Label(order.rawValue, systemImage: sortIcon(for: order))
                }
            }
        } label: {
            Image(systemName: sortIcon(for: viewModel.sortOrder))
                .font(.caption)
                .foregroundStyle(Ayu.fgSecondary)
                .frame(width: 28, height: 28)
                .background(Ayu.bgTertiary, in: RoundedRectangle(cornerRadius: Radius.xs))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort artists by \(viewModel.sortOrder.rawValue)")
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(BrowseFilter.allCases, id: \.self) { filter in
                FilterChip(
                    label: filter.rawValue,
                    isActive: viewModel.activeFilters.contains(filter),
                    onTap: {
                        if viewModel.activeFilters.contains(filter) {
                            viewModel.activeFilters.remove(filter)
                        } else {
                            viewModel.activeFilters.insert(filter)
                        }
                        viewModel.applyFilters()
                    }
                )
            }
            Spacer()
        }
    }

    // MARK: - Bulk Action Bar

    private var bulkActionBar: some View {
        HStack(spacing: Spacing.sm) {
            Text("\(viewModel.selectionCount) selected")
                .font(AppFont.caption)
                .foregroundStyle(Ayu.fgPrimary)

            Spacer()

            ForEach(BrowseUpdateAction.allCases, id: \.rawValue) { action in
                bulkButton(action)
            }

            Button {
                viewModel.clearSelection()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
                    .font(AppFont.caption)
                    .foregroundStyle(Ayu.fgSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(Ayu.bgSecondary)
                .shadow(
                    color: Shadow.subtle.color,
                    radius: Shadow.subtle.radius,
                    x: Shadow.subtle.x,
                    y: Shadow.subtle.y
                )
        }
        .accessibilityLabel("Bulk actions for \(viewModel.selectionCount) selected items")
    }

    // MARK: - Helpers

    private func bulkButton(_ action: BrowseUpdateAction) -> some View {
        Button {
            action.post(selectedItems: viewModel.selectedItems)
        } label: {
            Label(action.title, systemImage: action.iconName)
                .font(AppFont.caption)
                .foregroundStyle(Ayu.accent)
        }
        .buttonStyle(.plain)
    }

    private func sortIcon(for order: BrowseSortOrder) -> String {
        switch order {
        case .name: "textformat.abc"
        case .trackCount: "number"
        case .tagCompletion: "percent"
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let browseAction = Notification.Name("browseAction")
}

// MARK: - Preview

#Preview("BrowseToolbar") {
    BrowseToolbar(viewModel: BrowseViewModel())
        .padding()
        .frame(width: 500)
}
