import Foundation

/// The album-artist effect coupled to an artist rename.
///
/// Both values are retained so write recovery and undo can preserve the same
/// semantic operation across process restarts.
public struct AlbumArtistChange: Codable, Equatable, Sendable {
    public let oldValue: String
    public let newValue: String

    public init(oldValue: String, newValue: String) {
        self.oldValue = oldValue
        self.newValue = newValue
    }
}
