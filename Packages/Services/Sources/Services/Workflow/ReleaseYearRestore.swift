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
        var noOpEntries: [ChangeLogEntry] = []
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []
        var wasCancelled = false

        for (index, track) in candidates.enumerated() {
            guard !Task.isCancelled else {
                wasCancelled = true
                break
            }

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
                let outcome = try await applyChangeOutcome(change)
                if let entry = outcome.entry {
                    entries.append(entry)
                }
                if let noOpEntry = outcome.noOpEntry {
                    noOpEntries.append(noOpEntry)
                }
            } catch is CancellationError {
                wasCancelled = true
                break
            } catch {
                failedTrackIDs.append(track.id)
                errorDescriptions.append(error.localizedDescription)
            }
        }

        if !wasCancelled {
            progressHandler(ProgressUpdate(
                phase: .complete,
                current: candidates.count,
                total: candidates.count
            ))
        }

        return BatchUpdateResult(
            entries: entries,
            noOpEntries: noOpEntries,
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

        for track in tracks {
            guard let releaseYear = track.releaseYear else { continue }
            counts[releaseYear, default: 0] += 1
        }

        guard let maximumCount = counts.values.max() else { return nil }
        let consensusYears = counts.filter { $0.value == maximumCount }.map(\.key)
        return consensusYears.count == 1 ? consensusYears[0] : nil
    }
}
