extension ActivityLibraryState {
    var operationalIssue: OperationalIssue? {
        switch self {
        case let .permissionDenied(message):
            OperationalIssue(
                id: "music-permission-required",
                category: .musicPermissionRequired,
                summary: "Music permission required",
                technicalDetail: message
            )
        case let .failed(message):
            OperationalIssue(
                id: "music-library-unavailable",
                category: .musicUnavailable,
                summary: "Music library unavailable",
                technicalDetail: message
            )
        case .loading, .empty, .ready:
            nil
        }
    }
}
