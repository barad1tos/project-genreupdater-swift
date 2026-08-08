import Foundation

// MARK: - App State

/// Represents the current state of the application.
enum AppState {
    case loading
    case needsOnboarding
    case ready
    case error(String)
}

/// Initialization failures that must keep the app out of the ready state.
enum AppInitializationError: LocalizedError {
    case missingWorkflowPrerequisites([String])

    var errorDescription: String? {
        switch self {
        case let .missingWorkflowPrerequisites(names):
            "Cannot initialize workflow services — missing: \(names.joined(separator: ", "))"
        }
    }
}
