// AppFeature.swift — App features with minimum tier requirements.
// Feature list from PRD Section 7 Monetization table.

public enum AppFeature: String, CaseIterable, Sendable {
    case genreUpdate
    case yearUpdate
    case preview
    case undo
    case libraryBrowsing
    case basicCaching
    case batchProcessing
    case reportsLog
    case reportsCharts
    case artistAlbumCleaning
    case advancedCache
    case autoSync

    public var minimumTier: Tier {
        switch self {
        case .genreUpdate, .yearUpdate, .preview, .undo,
             .libraryBrowsing, .basicCaching, .reportsLog:
            .free
        case .batchProcessing, .reportsCharts,
             .artistAlbumCleaning, .advancedCache:
            .weekPass
        case .autoSync:
            .pro
        }
    }
}
