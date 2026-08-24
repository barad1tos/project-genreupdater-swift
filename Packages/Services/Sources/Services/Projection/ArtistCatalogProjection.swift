import Core
import Foundation

/// One normalized effective artist and its physical mirror track count.
public struct ArtistCatalogEntry: Equatable, Sendable {
    public let name: String
    public let trackCount: Int

    public init(name: String, trackCount: Int) {
        self.name = name
        self.trackCount = trackCount
    }
}

/// The complete catalog result or an actionable reason it is unavailable.
public enum ArtistCatalogState: Equatable, Sendable {
    case available([ArtistCatalogEntry])
    case unavailable(reason: String)
}

/// Revisioned full-library artist catalog published independently of processing scope.
public struct ArtistCatalogProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let state: ArtistCatalogState

    public init(revision: ProjectionRevision, state: ArtistCatalogState) {
        self.revision = revision
        self.state = state
    }

    /// Creates the initial unavailable projection before the mirror is ready.
    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(revision: revision, state: .unavailable(reason: "Artist catalog isn’t ready yet."))
    }

    func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(revision: revision, state: state)
    }
}

/// Pure assembly of artist catalog truth from the persisted track mirror.
public enum ArtistCatalogBuilder {
    /// Groups tracks by effective artist with deterministic display ordering.
    public static func makeProjection(tracks: [Track]) -> ArtistCatalogProjection {
        var entries: [String: ArtistCatalogEntry] = [:]

        for track in tracks {
            guard let artist = ArtistAllowList.normalizedName(track.effectiveArtist) else { continue }

            let key = artist.lowercased(with: .current)
            let trackCount = (entries[key]?.trackCount ?? 0) + 1
            entries[key] = ArtistCatalogEntry(name: entries[key]?.name ?? artist, trackCount: trackCount)
        }

        let sortedEntries = entries.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ArtistCatalogProjection(revision: .initial, state: .available(sortedEntries))
    }
}
