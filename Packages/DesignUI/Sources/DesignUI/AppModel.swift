import SwiftUI
import Observation

struct NavigationEntry: Hashable {
    let route: Route
    let browseFilter: BrowseFilter
}

/// Central app state — route, browse filter, onboarding, and the data source.
@Observable
final class AppModel {
    var route: Route? = .activity
    var browseFilter: BrowseFilter = .all
    var showOnboarding = false
    var dryRun = true

    private var backStack: [NavigationEntry] = []
    private var forwardStack: [NavigationEntry] = []

    let data = MockData()
    var snapshot: HealthSnapshot { data.snapshot }
    var pipelineActivity: PipelineActivitySnapshot { data.pipelineActivity }
    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    func openBrowse(filter: BrowseFilter) {
        navigate(to: .browse, browseFilter: filter)
    }

    func setBrowseFilter(_ filter: BrowseFilter) {
        if route == .browse {
            navigate(to: .browse, browseFilter: filter)
        } else {
            browseFilter = filter
        }
    }

    func navigate(to route: Route, browseFilter filter: BrowseFilter? = nil) {
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

    func navigateBack() {
        guard let previousEntry = backStack.popLast() else { return }

        forwardStack.append(currentNavigationEntry)
        apply(previousEntry)
    }

    func navigateForward() {
        guard let nextEntry = forwardStack.popLast() else { return }

        backStack.append(currentNavigationEntry)
        apply(nextEntry)
    }

    private var currentNavigationEntry: NavigationEntry {
        NavigationEntry(route: route ?? .activity, browseFilter: browseFilter)
    }

    private func apply(_ entry: NavigationEntry) {
        route = entry.route
        browseFilter = entry.browseFilter
    }
}
