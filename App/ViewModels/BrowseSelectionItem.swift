// BrowseSelectionItem.swift -- typed selection identifiers for Browse rows.

enum BrowseSelectionItem: Hashable {
    case artist(String)
    case album(String)
    case track(String)

    var id: String {
        switch self {
        case let .artist(artistID):
            "artist:\(artistID)"
        case let .album(albumID):
            "album:\(albumID)"
        case let .track(trackID):
            "track:\(trackID)"
        }
    }

    init?(id: String) {
        if id.hasPrefix("artist:") {
            self = .artist(String(id.dropFirst("artist:".count)))
        } else if id.hasPrefix("album:") {
            self = .album(String(id.dropFirst("album:".count)))
        } else if id.hasPrefix("track:") {
            self = .track(String(id.dropFirst("track:".count)))
        } else {
            return nil
        }
    }

    static func artistID(_ artistID: String) -> String {
        artist(artistID).id
    }

    static func albumID(_ albumID: String) -> String {
        album(albumID).id
    }

    static func trackID(_ trackID: String) -> String {
        track(trackID).id
    }
}
