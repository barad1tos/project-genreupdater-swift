import DesignUI
import SharedUI

extension NavigationCategory {
    var designRoute: Route {
        switch self {
        case .dashboard:
            .activity
        case .browse:
            .browse
        case .reports:
            .reports
        case .update:
            .update
        }
    }

    init?(designRoute: Route?) {
        switch designRoute ?? .activity {
        case .activity:
            self = .dashboard
        case .browse:
            self = .browse
        case .reports:
            self = .reports
        case .update:
            self = .update
        case .settings:
            return nil
        }
    }
}

func designAppearanceMode(from mode: AppearanceMode) -> DesignAppearanceMode {
    switch mode {
    case .system:
        .system
    case .light:
        .light
    case .dark:
        .dark
    }
}

func appAppearanceMode(from mode: DesignAppearanceMode) -> AppearanceMode {
    switch mode {
    case .system:
        .system
    case .light:
        .light
    case .dark:
        .dark
    }
}
