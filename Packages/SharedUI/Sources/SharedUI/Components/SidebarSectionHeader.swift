// SidebarSectionHeader.swift — Section header (expanded text) / divider (compact).

import SwiftUI

// MARK: - SidebarSectionHeader

/// Renders a section label in expanded mode or a thin divider in compact mode.
public struct SidebarSectionHeader: View {
    public let title: String
    public let isCompact: Bool

    public init(title: String, isCompact: Bool) {
        self.title = title
        self.isCompact = isCompact
    }

    public var body: some View {
        if isCompact {
            Divider()
                .padding(.vertical, Spacing.xs)
        } else {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ayu.fgSecondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxs)
        }
    }
}
