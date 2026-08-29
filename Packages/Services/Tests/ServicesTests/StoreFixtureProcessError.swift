import Foundation

enum FixtureProcessError: LocalizedError {
    case executableNotFound
    case failed(
        reason: Process.TerminationReason,
        status: Int32,
        standardOutput: String,
        standardError: String
    )

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "StoreFixtureGenerator was not found beside the Services test product."
        case let .failed(reason, status, standardOutput, standardError):
            """
            StoreFixtureGenerator failed with reason \(reason == .exit ? "exit" : "uncaughtSignal"), status \(status).
            stdout:
            \(standardOutput)
            stderr:
            \(standardError)
            """
        }
    }
}
