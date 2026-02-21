import Core
import Foundation
import OSLog

// MARK: - Track ID Mapper

/// Maps MusicKit IDs to AppleScript persistent IDs by matching on (name, artist, album).
///
/// MusicKit returns numeric `MusicItemID` strings while AppleScript uses hex
/// persistent IDs. These are different ID spaces with no direct translation.
/// This actor builds a lookup table by matching tracks on their metadata tuple.
public actor TrackIDMapper: TrackIDMapping {
    private var mapping: [String: String] = [:]
    private let log = Logger(subsystem: "com.genreupdater", category: "TrackIDMapper")

    public init() {}

    public func refreshMapping(
        musicKitTracks: [Track],
        appleScriptTracks: [Track]
    ) {
        var appleScriptLookup: [String: String] = [:]
        for track in appleScriptTracks {
            let key = normalizedKey(track)
            appleScriptLookup[key] = track.id
        }

        mapping = [:]
        for track in musicKitTracks {
            let key = normalizedKey(track)
            if let appleScriptID = appleScriptLookup[key] {
                mapping[track.id] = appleScriptID
            }
        }

        log
            .info(
                "Built ID mapping: \(self.mapping.count, privacy: .public)/\(musicKitTracks.count, privacy: .public) matched"
            )
    }

    public func appleScriptID(forMusicKitID musicKitID: String) -> String? {
        mapping[musicKitID]
    }

    public func hasMappingFor(musicKitID: String) -> Bool {
        mapping[musicKitID] != nil
    }

    private func normalizedKey(_ track: Track) -> String {
        "\(track.name.lowercased())|\(track.artist.lowercased())|\(track.album.lowercased())"
    }
}
