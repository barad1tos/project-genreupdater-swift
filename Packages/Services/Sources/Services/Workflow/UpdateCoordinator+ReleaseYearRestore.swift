import Core
import Foundation

extension UpdateCoordinator {
    /// Restore editable track years from Music.app release-year metadata when the gap exceeds a threshold.
    public func restoreReleaseYears(
        in tracks: [Track],
        threshold: Int,
        progressHandler: @Sendable (ProgressUpdate) -> Void
    ) async -> BatchUpdateResult {
        let candidates = Self.tracksNeedingReleaseYearRestore(tracks, threshold: threshold)
        let consensusByAlbum = Self.releaseYearConsensusByAlbum(for: candidates)
        var entries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        for (index, track) in candidates.enumerated() {
            progressHandler(ProgressUpdate(
                phase: .updating,
                current: index + 1,
                total: candidates.count,
                message: "\(track.albumIdentity.artist) - \(track.album)"
            ))

            guard let releaseYear = consensusByAlbum[Self.albumKey(for: track)] else { continue }
            let change = ProposedChange(
                track: track,
                changeType: .yearRevert,
                oldValue: track.year.map(String.init),
                newValue: String(releaseYear),
                confidence: 100,
                source: "Release Year"
            )

            do {
                if let entry = try await applyChange(change) {
                    entries.append(entry)
                }
            } catch {
                failedTrackIDs.append(track.id)
                errorDescriptions.append(error.localizedDescription)
            }
        }

        progressHandler(ProgressUpdate(
            phase: .complete,
            current: candidates.count,
            total: candidates.count
        ))

        return BatchUpdateResult(
            entries: entries,
            failedTrackIDs: failedTrackIDs,
            errorDescriptions: errorDescriptions
        )
    }

    public static func tracksNeedingReleaseYearRestore(
        _ tracks: [Track],
        threshold: Int
    ) -> [Track] {
        tracks.filter { shouldRestoreReleaseYear(for: $0, threshold: threshold) }
    }

    static func releaseYearConsensusByAlbum(for tracks: [Track]) -> [String: Int] {
        let groupedTracks = Dictionary(grouping: tracks) { track in
            Self.albumKey(for: track)
        }
        return Dictionary(uniqueKeysWithValues: groupedTracks.compactMap { key, albumTracks in
            guard let releaseYear = mostCommonReleaseYear(in: albumTracks) else { return nil }
            return (key, releaseYear)
        })
    }

    static func albumKey(for track: Track) -> String {
        AlbumIdentity.key(for: track)
    }

    private static func shouldRestoreReleaseYear(for track: Track, threshold: Int) -> Bool {
        guard track.canEdit, let releaseYear = track.releaseYear else { return false }
        guard let year = track.year else { return true }
        return abs(year - releaseYear) > threshold
    }

    private static func mostCommonReleaseYear(in tracks: [Track]) -> Int? {
        var counts: [Int: Int] = [:]
        var firstIndex: [Int: Int] = [:]

        for (index, track) in tracks.enumerated() {
            guard let releaseYear = track.releaseYear else { continue }
            counts[releaseYear, default: 0] += 1
            firstIndex[releaseYear, default: index] = min(firstIndex[releaseYear, default: index], index)
        }

        return counts.max { left, right in
            if left.value == right.value {
                return (firstIndex[left.key] ?? 0) > (firstIndex[right.key] ?? 0)
            }
            return left.value < right.value
        }?.key
    }
}
