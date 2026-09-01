import Core
import Foundation

public enum PreviewRunOptions {
    public static func make(
        configuration: AppConfiguration,
        updateGenre: Bool,
        updateYear: Bool,
        forceYearLookup: Bool = false
    ) -> UpdateOptions {
        let minConfidence = UpdateOptions.clampedConfidencePercent(
            fromRatio: configuration.yearRetrieval.logic.minConfidenceForNewYear / 100
        )
        return UpdateOptions(
            updateGenre: updateGenre,
            updateYear: updateYear,
            repairExistingGenreMismatches: false,
            forceYearLookup: forceYearLookup,
            cleanTrackNames: false,
            cleanAlbumNames: false,
            minConfidence: minConfidence,
            autoAccept: false
        )
    }
}
