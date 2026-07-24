import Foundation

/// Errors from AppleScript execution.
public enum AppleScriptBridgeError: Error, LocalizedError {
    case scriptNotFound(name: String, searchPath: URL)
    case executionFailed(scriptName: String, detail: String)
    case dispatchDeadline(scriptName: String, duration: Duration)
    case timeout(scriptName: String, duration: Duration)
    case parseError(scriptName: String, detail: String)
    case libraryChanged(detail: String)
    case invalidLibraryPath
    case scriptsNotInstalled
    case musicAppNotRunning

    public var errorDescription: String? {
        switch self {
        case let .scriptNotFound(name, path):
            "Script '\(name).scpt' not found at \(path.path)"
        case let .executionFailed(name, detail):
            "AppleScript '\(name)' failed: \(detail)"
        case let .dispatchDeadline(name, duration):
            "AppleScript '\(name)' was not dispatched before its \(duration) deadline"
        case let .timeout(name, duration):
            "AppleScript '\(name)' timed out after \(duration)"
        case let .parseError(name, detail):
            "Failed to parse output from '\(name)': \(detail)"
        case let .libraryChanged(detail):
            "Music library changed while it was being read: \(detail)"
        case .invalidLibraryPath:
            "The configured Music library does not contain Library.musicdb. Check the configured library path."
        case .scriptsNotInstalled:
            "AppleScript files are not installed. Please run the setup wizard."
        case .musicAppNotRunning:
            "Music.app is not running. Please start Music.app before using Genre Updater."
        }
    }
}
