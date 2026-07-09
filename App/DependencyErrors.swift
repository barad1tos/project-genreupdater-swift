import Foundation

enum DependencySetupError: LocalizedError {
    case missingModelContainer

    var errorDescription: String? {
        switch self {
        case .missingModelContainer:
            "SwiftData model container is unavailable"
        }
    }
}

enum PreviewRunError: LocalizedError {
    case appDependenciesReleased

    var errorDescription: String? {
        switch self {
        case .appDependenciesReleased:
            "App dependencies were released before the preview run"
        }
    }
}
