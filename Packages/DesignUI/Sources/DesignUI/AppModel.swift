import Observation
import SwiftUI

struct NavigationEntry: Hashable {
    let route: Route
    let browseFilter: BrowseFilter
}

/// Central app state — route, browse filter, onboarding, and the data source.
@Observable
@MainActor
public final class AppModel {
    public var route: Route? = .activity
    public var browseFilter: BrowseFilter = .all
    public var showOnboarding = false
    public var dryRun = true
    public var data: DesignDataSnapshot

    private var backStack: [NavigationEntry] = []
    private var forwardStack: [NavigationEntry] = []

    public init(data: DesignDataSnapshot = .preview) {
        self.data = data
        dryRun = data.pipelineActivity.safetyMode == .preview
    }

    public var snapshot: HealthSnapshot {
        data.health
    }
    public var pipelineActivity: PipelineActivitySnapshot {
        data.pipelineActivity
    }
    public var canNavigateBack: Bool {
        !backStack.isEmpty
    }
    public var canNavigateForward: Bool {
        !forwardStack.isEmpty
    }

    public func openBrowse(filter: BrowseFilter) {
        navigate(to: .browse, browseFilter: filter)
    }

    public func setBrowseFilter(_ filter: BrowseFilter) {
        if route == .browse {
            navigate(to: .browse, browseFilter: filter)
        } else {
            browseFilter = filter
        }
    }

    public func navigate(to route: Route, browseFilter filter: BrowseFilter? = nil) {
        let nextEntry = NavigationEntry(
            route: route,
            browseFilter: route == .browse ? (filter ?? browseFilter) : browseFilter
        )
        let currentEntry = currentNavigationEntry

        guard nextEntry != currentEntry else { return }

        backStack.append(currentEntry)
        forwardStack.removeAll()
        apply(nextEntry)
    }

    public func navigateBack() {
        guard let previousEntry = backStack.popLast() else { return }

        forwardStack.append(currentNavigationEntry)
        apply(previousEntry)
    }

    public func navigateForward() {
        guard let nextEntry = forwardStack.popLast() else { return }

        backStack.append(currentNavigationEntry)
        apply(nextEntry)
    }

    public func applyData(_ data: DesignDataSnapshot) {
        self.data = data
        dryRun = data.pipelineActivity.safetyMode == .preview
    }

    private var currentNavigationEntry: NavigationEntry {
        NavigationEntry(route: route ?? .activity, browseFilter: browseFilter)
    }

    private func apply(_ entry: NavigationEntry) {
        route = entry.route
        browseFilter = entry.browseFilter
    }
}
