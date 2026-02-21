// EmptyStateView.swift — Configurable empty state placeholder.

import SwiftUI

// MARK: - EmptyStateView

/// Centered placeholder view for empty content states.
///
/// Shows an SF Symbol icon, title, description, and an optional call-to-action button.
public struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    /// Creates an empty state placeholder.
    ///
    /// - Parameters:
    ///   - icon: SF Symbol name for the icon.
    ///   - title: Primary heading text.
    ///   - description: Secondary explanatory text.
    ///   - actionTitle: Optional button label. Button only appears when both title and action are provided.
    ///   - action: Optional callback invoked when the button is tapped.
    public init(
        icon: String,
        title: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2)
                .bold()

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Double-tap to \(actionTitle.lowercased())")
                    .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview("Empty State") {
    EmptyStateView(
        icon: "music.note.list",
        title: "No Tracks Found",
        description: "Your library appears to be empty. Add some music to get started.",
        actionTitle: "Refresh Library"
    ) {
        // preview action
    }
}
