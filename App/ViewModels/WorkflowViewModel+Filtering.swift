// WorkflowViewModel+Filtering.swift -- Smart filters and workflow error handling.

import Core
import Services

// MARK: - Smart Filter + Error Handling

extension WorkflowViewModel {
    var hasEnabledOperation: Bool {
        updateGenre || updateYear || cleanTrackNames || cleanAlbumNames
    }

    func applySmartFilter(to tracks: [Track]) -> [Track] {
        guard mode == .smartFilter else { return tracks }
        switch smartFilterType {
        case .missingGenres:
            return tracks.filter { $0.genre == nil || $0.genre?.isEmpty == true }
        case .missingYears:
            return tracks.filter { $0.year == nil }
        case .lowConfidence:
            return tracks
        }
    }

    func handleBatchError(_ error: BatchProcessorError) {
        switch error {
        case let .cancelled(processedCount, _):
            self.processedCount = processedCount
            phase = .configure
        case .featureNotAvailable, .alreadyRunning, .notRunning:
            phase = .error(error.localizedDescription)
        }
        progress = nil
    }
}
