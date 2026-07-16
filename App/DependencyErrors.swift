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

enum WriteAdmissionError: LocalizedError {
    case recoveryRequired

    var errorDescription: String? {
        "Verify the previous Music.app outcome before another write."
    }
}
