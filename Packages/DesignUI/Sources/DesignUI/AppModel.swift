import SwiftUI
import Observation

/// Central app state — route, browse filter, onboarding, and the data source.
@Observable
final class AppModel {
    var route: Route? = .activity
    var browseFilter: BrowseFilter = .all
    var showOnboarding = false
    var dryRun = true

    let data = MockData()
    var snapshot: HealthSnapshot { data.snapshot }
    var pipelineActivity: PipelineActivitySnapshot { data.pipelineActivity }

    func openBrowse(filter: BrowseFilter) {
        browseFilter = filter
        route = .browse
    }
}
