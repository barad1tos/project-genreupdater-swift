import Foundation

/// Immutable snapshot of the determination-shaping `UpdateOptions` knobs at the
/// moment a fix plan was proposed (ADR 0017).
///
/// Deliberately excludes `autoAccept`: that knob governs write authority, not
/// change determination (ADR 0001).
public struct FixPlanConfigurationSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let updateGenre: Bool
    public let updateYear: Bool
    public let repairExistingGenreMismatches: Bool
    public let forceYearLookup: Bool
    public let cleanTrackNames: Bool
    public let cleanAlbumNames: Bool
    public let minConfidence: Int
    public let fingerprint: String

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        updateGenre: Bool,
        updateYear: Bool,
        repairExistingGenreMismatches: Bool,
        forceYearLookup: Bool,
        cleanTrackNames: Bool,
        cleanAlbumNames: Bool,
        minConfidence: Int,
        fingerprint: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.updateGenre = updateGenre
        self.updateYear = updateYear
        self.repairExistingGenreMismatches = repairExistingGenreMismatches
        self.forceYearLookup = forceYearLookup
        self.cleanTrackNames = cleanTrackNames
        self.cleanAlbumNames = cleanAlbumNames
        self.minConfidence = minConfidence
        self.fingerprint = fingerprint
    }

    public static func capture(options: UpdateOptions, capturedAt: Date) -> Self {
        Self(
            capturedAt: capturedAt,
            updateGenre: options.updateGenre,
            updateYear: options.updateYear,
            repairExistingGenreMismatches: options.repairExistingGenreMismatches,
            forceYearLookup: options.forceYearLookup,
            cleanTrackNames: options.cleanTrackNames,
            cleanAlbumNames: options.cleanAlbumNames,
            minConfidence: options.minConfidence,
            fingerprint: """
            genre=\(options.updateGenre):year=\(options.updateYear):\
            repair=\(options.repairExistingGenreMismatches):forceYear=\(options.forceYearLookup):\
            cleanTracks=\(options.cleanTrackNames):cleanAlbums=\(options.cleanAlbumNames):\
            minConfidence=\(options.minConfidence)
            """
        )
    }
}
