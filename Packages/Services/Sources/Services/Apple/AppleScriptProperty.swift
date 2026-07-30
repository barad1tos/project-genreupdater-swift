import Core

enum AppleScriptTrackProperty: String, CaseIterable {
    case genre
    case year
    case name
    case album
    case artist
    case albumArtist = "album_artist"

    static let supportedNames = Set(allCases.map(\.rawValue))

    init(changeType: ChangeType) {
        self = switch changeType {
        case .genreUpdate: .genre
        case .yearUpdate, .yearRevert: .year
        case .trackCleaning: .name
        case .albumCleaning: .album
        case .artistRename: .artist
        }
    }

    func currentValue(in track: Track) -> String? {
        switch self {
        case .genre:
            track.genre ?? ""
        case .year:
            track.year.map(String.init) ?? ""
        case .name:
            track.name
        case .album:
            track.album
        case .artist:
            track.artist
        case .albumArtist:
            track.albumArtist ?? ""
        }
    }
}
