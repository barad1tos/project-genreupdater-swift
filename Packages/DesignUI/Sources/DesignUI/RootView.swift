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
    private let setBulkThresholdAction: ((Int) -> Bool)?
    private let setTestArtistsAction: ((ArtistScopeChange) -> ArtistScopeSaveResult)?
    private let setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)?
    private let setFastAnimationsAction: ((Bool) -> Bool)?
    private let browseTrackRows: ((Album.ID) -> [DesignBrowseTrackRow])?
    private let browseAlbumPreviewAction: ((Album.ID) -> Void)?
    private let browseNotice: String?
    private let reportRunSelectionAction: ((String?) -> Void)?
    private let recoveryDetailActions: RecoveryDetailActions?
    private let reportAnalyticsAccess: ContentAccess
    private let reportNotice: ReportNotice?
    private let selectAnalyticsWindow: ((DesignAnalyticsWindow) -> Void)?
    private let retryAnalytics: (() -> Void)?
    private let openAnalyticsSettings: (() -> Void)?
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
        setBulkThresholdAction: ((Int) -> Bool)? = nil,
        setTestArtistsAction: ((ArtistScopeChange) -> ArtistScopeSaveResult)? = nil,
        setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)? = nil,
        setFastAnimationsAction: ((Bool) -> Bool)? = nil,
        browseTrackRows: ((Album.ID) -> [DesignBrowseTrackRow])? = nil,
        browseAlbumPreviewAction: ((Album.ID) -> Void)? = nil,
        browseNotice: String? = nil,
        reportRunSelectionAction: ((String?) -> Void)? = nil,
        recoveryDetailActions: RecoveryDetailActions?,
        reportAnalyticsAccess: ContentAccess = .available,
        selectAnalyticsWindow: ((DesignAnalyticsWindow) -> Void)? = nil,
        retryAnalytics: (() -> Void)? = nil,
        openAnalyticsSettings: (() -> Void)? = nil,
        // No default: the host must pass its notice state explicitly —
        // a defaulted nil once let the whole chain die silently.
        reportNotice: ReportNotice?,
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
        self.setBulkThresholdAction = setBulkThresholdAction
        self.setTestArtistsAction = setTestArtistsAction
        self.setAppearanceModeAction = setAppearanceModeAction
        self.setFastAnimationsAction = setFastAnimationsAction
        self.browseTrackRows = browseTrackRows
        self.browseAlbumPreviewAction = browseAlbumPreviewAction
        self.browseNotice = browseNotice
        self.reportRunSelectionAction = reportRunSelectionAction
        self.recoveryDetailActions = recoveryDetailActions
        self.reportAnalyticsAccess = reportAnalyticsAccess
        self.selectAnalyticsWindow = selectAnalyticsWindow
        self.retryAnalytics = retryAnalytics
        self.openAnalyticsSettings = openAnalyticsSettings
        self.reportNotice = reportNotice
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
                SyncStatusPill(chrome: model.data.chrome)
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
                trackRows: browseTrackRows,
                albumPreviewAction: browseAlbumPreviewAction,
                notice: browseNotice
            )
        case .reports: ReportsView(
                model: model,
                runSelectionAction: reportRunSelectionAction,
                recoveryActions: recoveryDetailActions,
                analyticsAccess: reportAnalyticsAccess,
                reportNotice: reportNotice
            )
        case .analytics:
            AnalyticsView(
                snapshot: model.data.analytics,
                selectWindow: { selectAnalyticsWindow?($0) },
                retry: { retryAnalytics?() },
                openSettings: { openAnalyticsSettings?() }
            )
        case .update: updateContent()
        case .settings:
            SettingsScreen(
                model: model,
                setDryRunAction: setDryRunAction,
                setUpdateBehaviorAction: setUpdateBehaviorAction,
                setMinimumConfidenceAction: setMinimumConfidenceAction,
                setReleaseYearRestoreThresholdAction: setReleaseYearRestoreThresholdAction,
                setBulkThresholdAction: setBulkThresholdAction,
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
    let chrome: DesignChromeSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(severityColor.opacity(0.88))
                .frame(width: 6, height: 6)

            Text(chrome.syncStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ayu.fg2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel(accessibilityText)
    }

    /// The dot renders the projection's severity — the shell must never
    /// invent its own status colour (ADR 0012).
    private var severityColor: Color {
        switch chrome.syncSeverity {
        case .nominal: Ayu.success
        case .attention: Ayu.warning
        case .blocked: Ayu.error
        }
    }

    private var accessibilityText: String {
        chrome.syncSeverity == .nominal
            ? chrome.syncStatusText
            : "\(chrome.syncStatusText) — needs attention"
    }
}

#Preview {
    RootView(recoveryDetailActions: nil, reportNotice: nil) {
        UpdateView(model: AppModel(data: .preview))
    }
}
