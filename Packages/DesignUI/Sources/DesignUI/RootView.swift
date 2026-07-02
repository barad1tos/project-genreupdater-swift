import SwiftUI

/// Root shell: native NavigationSplitView (vibrancy sidebar + window traffic
/// lights come free on macOS). Detail switches on the selected route.
public struct RootView<UpdateContent: View>: View {
    // `data` is the injected prop; `model.data` is the live value read by views.
    private let data: DesignDataSnapshot
    private let selectedRoute: Binding<Route?>?
    private let pipelinePrimaryAction: (() -> Void)?
    private let pipelineSecondaryAction: ((PipelineAction) -> Void)?
    private let setDryRunAction: ((Bool) -> Bool)?
    private let setUpdateBehaviorAction: ((DesignUpdateBehavior) -> Bool)?
    private let setMinimumConfidenceAction: ((Double) -> Bool)?
    private let setReleaseYearRestoreThresholdAction: ((Int) -> Bool)?
    private let setTestArtistsAction: (([String]) -> Bool)?
    private let setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)?
    private let setFastAnimationsAction: ((Bool) -> Bool)?
    private let browseAlbumUpdateAction: ((Album, String) -> Void)?
    private let browseAlbumSelectionAction: ((Album?, String?) -> Void)?
    private let updateContent: () -> UpdateContent
    @State private var model: AppModel

    public init(
        data: DesignDataSnapshot = .preview,
        selectedRoute: Binding<Route?>? = nil,
        pipelinePrimaryAction: (() -> Void)? = nil,
        pipelineSecondaryAction: ((PipelineAction) -> Void)? = nil,
        setDryRunAction: ((Bool) -> Bool)? = nil,
        setUpdateBehaviorAction: ((DesignUpdateBehavior) -> Bool)? = nil,
        setMinimumConfidenceAction: ((Double) -> Bool)? = nil,
        setReleaseYearRestoreThresholdAction: ((Int) -> Bool)? = nil,
        setTestArtistsAction: (([String]) -> Bool)? = nil,
        setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)? = nil,
        setFastAnimationsAction: ((Bool) -> Bool)? = nil,
        browseAlbumUpdateAction: ((Album, String) -> Void)? = nil,
        browseAlbumSelectionAction: ((Album?, String?) -> Void)? = nil,
        @ViewBuilder updateContent: @escaping () -> UpdateContent
    ) {
        self.data = data
        self.selectedRoute = selectedRoute
        self.pipelinePrimaryAction = pipelinePrimaryAction
        self.pipelineSecondaryAction = pipelineSecondaryAction
        self.setDryRunAction = setDryRunAction
        self.setUpdateBehaviorAction = setUpdateBehaviorAction
        self.setMinimumConfidenceAction = setMinimumConfidenceAction
        self.setReleaseYearRestoreThresholdAction = setReleaseYearRestoreThresholdAction
        self.setTestArtistsAction = setTestArtistsAction
        self.setAppearanceModeAction = setAppearanceModeAction
        self.setFastAnimationsAction = setFastAnimationsAction
        self.browseAlbumUpdateAction = browseAlbumUpdateAction
        self.browseAlbumSelectionAction = browseAlbumSelectionAction
        self.updateContent = updateContent
        _model = State(initialValue: AppModel(data: data))
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Ayu.accent)
        .preferredColorScheme(model.data.settings.appearanceMode.designPreferredColorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                NavigationHistoryControls(model: model)
            }
            ToolbarItem(placement: .automatic) {
                SyncStatusPill(text: model.data.syncStatusText)
            }
        }
        .onChange(of: data) { _, newData in
            model.applyData(newData)
        }
        .onChange(of: model.route) { _, route in
            guard selectedRoute?.wrappedValue != route else { return }
            selectedRoute?.wrappedValue = route
        }
        .onChange(of: selectedRouteValue) { _, route in
            guard route != model.route else { return }
            model.navigate(to: route ?? .activity)
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView { model.showOnboarding = false }
        }
    }

    private var selectedRouteValue: Route? {
        selectedRoute?.wrappedValue
    }

    @ViewBuilder private var detail: some View {
        switch model.route ?? .activity {
        case .activity:
            ActivityView(
                model: model,
                pipelinePrimaryAction: pipelinePrimaryAction,
                pipelineSecondaryAction: pipelineSecondaryAction
            )
        case .browse:
            BrowseView(
                model: model,
                albumUpdateAction: browseAlbumUpdateAction,
                albumSelectionAction: browseAlbumSelectionAction
            )
        case .reports: ReportsView(model: model)
        case .update: updateContent()
        case .settings:
            SettingsScreen(
                model: model,
                setDryRunAction: setDryRunAction,
                setUpdateBehaviorAction: setUpdateBehaviorAction,
                setMinimumConfidenceAction: setMinimumConfidenceAction,
                setReleaseYearRestoreThresholdAction: setReleaseYearRestoreThresholdAction,
                setTestArtistsAction: setTestArtistsAction,
                setAppearanceModeAction: setAppearanceModeAction,
                setFastAnimationsAction: setFastAnimationsAction
            )
        }
    }
}

extension DesignAppearanceMode {
    fileprivate var designPreferredColorScheme: ColorScheme? {
        // DesignUI uses dark-only Ayu tokens until a full light palette exists.
        .dark
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

    private func historyButton(
        symbol: String,
        label: String,
        isEnabled: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
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
    RootView {
        UpdateView(model: AppModel(data: .preview))
    }
}
