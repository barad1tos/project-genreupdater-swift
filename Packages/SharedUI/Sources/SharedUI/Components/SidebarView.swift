// SidebarView.swift — Full sidebar container with sections, toggle, settings footer.

import SwiftUI

// MARK: - SidebarBadge

/// Compact status badge metadata for a sidebar item.
public struct SidebarBadge: Sendable, Equatable {
    public enum Tone: Sendable {
        case neutral
        case info
        case success
        case warning
        case critical
    }

    public let value: String
    public let tone: Tone
    public let accessibilityLabel: String

    public init(
        value: String,
        tone: Tone = .neutral,
        accessibilityLabel: String
    ) {
        self.value = value
        self.tone = tone
        self.accessibilityLabel = accessibilityLabel
    }
}

// MARK: - SidebarView

/// Custom VStack-based sidebar with compact/expanded toggle,
/// sectioned items with Lucide icons, optional status badges, and a settings footer.
///
/// The sidebar supports two modes:
/// - **Expanded**: icon + text label with optional trailing badge
/// - **Compact**: icon-only with tooltips and compact badge markers
///
/// The active item uses `matchedGeometryEffect` for a sliding pill indicator.
public struct SidebarView: View {
    /// A single sidebar navigation item.
    public struct Item: Identifiable {
        public let id: String
        public let title: String
        public let icon: NSImage
        public let section: String
        public let badge: SidebarBadge?

        public init(
            id: String,
            title: String,
            icon: NSImage,
            section: String,
            badge: SidebarBadge? = nil
        ) {
            self.id = id
            self.title = title
            self.icon = icon
            self.section = section
            self.badge = badge
        }
    }

    @Binding var selectedItemID: String?
    let items: [Item]
    let onSettingsTapped: () -> Void

    @AppStorage("sidebarCompact") private var isCompact = false
    @Namespace private var sidebarNamespace
    @State private var settingsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        selectedItemID: Binding<String?>,
        items: [Item],
        onSettingsTapped: @escaping () -> Void
    ) {
        self._selectedItemID = selectedItemID
        self.items = items
        self.onSettingsTapped = onSettingsTapped
    }

    public var body: some View {
        VStack(spacing: 0) {
            sidebarToggle
            itemList
            Spacer()
            settingsFooter
        }
        .background(Color.clear)
    }

    // MARK: - Toggle Button

    private var sidebarToggle: some View {
        Button {
            withAnimation(Motion.curveDefault) {
                isCompact.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(Ayu.fgSecondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .frame(
            maxWidth: .infinity,
            alignment: isCompact ? .center : .trailing
        )
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollView {
            VStack(spacing: Spacing.xxs) {
                ForEach(sectionOrder, id: \.self) { section in
                    SidebarSectionHeader(title: section, isCompact: isCompact)

                    ForEach(items.filter { $0.section == section }) { item in
                        SidebarItemView(
                            title: item.title,
                            icon: item.icon,
                            badge: item.badge,
                            isSelected: selectedItemID == item.id,
                            isCompact: isCompact,
                            namespace: sidebarNamespace
                        ) {
                            let animation = reduceMotion ? .default : Motion.curveSmooth
                            withAnimation(animation) {
                                selectedItemID = item.id
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    // MARK: - Settings Footer

    private var settingsFooter: some View {
        Button(action: onSettingsTapped) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
                if !isCompact {
                    Text("Settings")
                        .font(AppFont.body)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
            .foregroundStyle(Ayu.fgSecondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .padding(.bottom, Spacing.xs)
        .background {
            if settingsHovered {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Ayu.bgTertiary)
            }
        }
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(Motion.curveFast) {
                settingsHovered = hovering
            }
        }
        .help(isCompact ? "Settings" : "")
    }

    // MARK: - Helpers

    /// Ordered unique sections preserving the items array order.
    private var sectionOrder: [String] {
        items.reduce(into: [String]()) { result, item in
            guard !result.contains(item.section) else { return }
            result.append(item.section)
        }
    }
}
