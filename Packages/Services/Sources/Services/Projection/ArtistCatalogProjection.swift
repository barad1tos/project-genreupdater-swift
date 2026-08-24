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

/// Pure assembly of artist catalog truth from a complete library track snapshot.
public enum ArtistCatalogBuilder {
    /// Groups tracks by effective artist with deterministic display ordering.
    public static func makeProjection(tracks: [Track]) -> ArtistCatalogProjection {
        let artists = tracks.enumerated().compactMap { index, track -> (index: Int, name: String)? in
            guard let name = ArtistAllowList.normalizedName(track.effectiveArtist) else { return nil }
            return (index, name)
        }.sorted { first, second in
            let comparison = first.name.localizedCaseInsensitiveCompare(second.name)
            if comparison == .orderedSame {
                return first.index < second.index
            }
            return comparison == .orderedAscending
        }

        var entries: [ArtistCatalogEntry] = []
        for artist in artists {
            if let lastIndex = entries.indices.last,
               entries[lastIndex].name.localizedCaseInsensitiveCompare(artist.name) == .orderedSame {
                let entry = entries[lastIndex]
                entries[lastIndex] = ArtistCatalogEntry(name: entry.name, trackCount: entry.trackCount + 1)
            } else {
                entries.append(ArtistCatalogEntry(name: artist.name, trackCount: 1))
            }
        }

        entries.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ArtistCatalogProjection(revision: .initial, state: .available(entries))
    }
}
