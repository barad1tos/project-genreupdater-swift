import SwiftUI

/// Root shell: native NavigationSplitView (vibrancy sidebar + window traffic
/// lights come free on macOS). Detail switches on the selected route.
public struct RootView: View {
    @State private var model = AppModel()

    public init() {}

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
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Circle().fill(Ayu.success).frame(width: 7, height: 7)
                    Text("Synced 8m ago").font(.system(size: 12)).foregroundStyle(Ayu.fg2)
                }
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView { model.showOnboarding = false }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.route ?? .dashboard {
        case .dashboard: DashboardView(model: model)
        case .browse:    BrowseView(model: model)
        case .reports:   ReportsView(model: model)
        case .update:    UpdateView(model: model)
        case .settings:  SettingsScreen(model: model)
        }
    }
}

#Preview {
    RootView()
}
