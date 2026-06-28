import SwiftUI

/// Root shell: native NavigationSplitView (vibrancy sidebar + window traffic
/// lights come free on macOS). Detail switches on the selected route.
public struct RootView: View {
    // `data` is the injected prop; `model.data` is the live value read by views.
    private let data: DesignDataSnapshot
    @State private var model: AppModel

    public init(data: DesignDataSnapshot = .preview) {
        self.data = data
        _model = State(initialValue: AppModel(data: data))
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .tint(Ayu.accent)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                NavigationHistoryControls(model: model)
            }
            ToolbarItem(placement: .automatic) {
                SyncStatusPill(text: model.data.syncStatusText)
            }
        }
        .onChange(of: data) { _, newData in
            model.data = newData
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView { model.showOnboarding = false }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.route ?? .activity {
        case .activity: ActivityView(model: model)
        case .browse:   BrowseView(model: model)
        case .reports:  ReportsView(model: model)
        case .update:   UpdateView(model: model)
        case .settings: SettingsScreen(model: model)
        }
    }
}

private struct NavigationHistoryControls: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            historyButton(
                symbol: "chevron.left",
                label: "Back",
                isEnabled: model.canNavigateBack,
                shortcut: "[",
                action: model.navigateBack
            )
            historyButton(
                symbol: "chevron.right",
                label: "Forward",
                isEnabled: model.canNavigateForward,
                shortcut: "]",
                action: model.navigateForward
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func historyButton(symbol: String, label: String, isEnabled: Bool, shortcut: KeyEquivalent,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Ayu.fg : Ayu.fgMuted.opacity(0.55))
        .disabled(!isEnabled)
        .keyboardShortcut(shortcut, modifiers: .command)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct SyncStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Ayu.success.opacity(0.88))
                .frame(width: 6, height: 6)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ayu.fg2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel(text)
    }
}

#Preview {
    RootView()
}
