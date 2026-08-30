import Core
import Foundation
import OSLog

struct BestEffortInvalidator {
    private let cache: (any CacheService)?
    private let snapshot: (any LibrarySnapshotService)?
    private let log = Logger(subsystem: "com.genreupdater", category: "BestEffortInvalidator")

    init(
        cache: (any CacheService)?,
        snapshot: (any LibrarySnapshotService)?
    ) {
        self.cache = cache
        self.snapshot = snapshot
    }

    func invalidate(targets: [(artist: String, album: String)]) async {
        if let cache {
            for target in targets {
                await invalidateAlbumYear(target, cache: cache)
                await invalidateAPIResults(target, cache: cache)
            }
        }
        await invalidateSnapshot()
    }

    private func invalidateAlbumYear(
        _ target: (artist: String, album: String),
        cache: any CacheService
    ) async {
        do {
            try await cache.invalidateAlbum(artist: target.artist, album: target.album)
        } catch {
            log.error(
                "Album-year cache invalidation failed for artist \(target.artist, privacy: .private), album \(target.album, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func invalidateAPIResults(
        _ target: (artist: String, album: String),
        cache: any CacheService
    ) async {
        do {
            try await cache.invalidateCachedAPIResults(artist: target.artist, album: target.album)
        } catch {
            log.error(
                "API-result cache invalidation failed for artist \(target.artist, privacy: .private), album \(target.album, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func invalidateSnapshot() async {
        guard let snapshot else { return }
        do {
            try await snapshot.clearSnapshot()
        } catch {
            log.error("Library snapshot invalidation failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

extension UpdateCoordinator {
    static func musicProperty(for changeType: ChangeType) -> MusicTrackProperty {
        MusicTrackProperty(changeType: changeType)
    }

    static func value(for property: MusicTrackProperty, in track: Track) -> String? {
        property.currentValue(in: track)
    }

    static func isTrackAvailableForProcessing(_ track: Track) -> Bool {
        track.kind?.isAvailableForProcessing ?? true
    }

    static func validateMutationEligibility(
        for track: Track,
        requiresKnownStatus: Bool,
        errorTrackID: String? = nil
    ) throws {
        let reportedTrackID = errorTrackID ?? track.id
        if requiresKnownStatus, track.kind == nil {
            throw UpdateCoordinatorError.trackNotProcessable(
                trackID: reportedTrackID,
                status: mutationStatusDescription(track.trackStatus)
            )
        }
        guard track.canEdit else {
            throw UpdateCoordinatorError.trackNotEditable(trackID: reportedTrackID)
        }
        guard isTrackAvailableForProcessing(track) else {
            throw UpdateCoordinatorError.trackNotProcessable(
                trackID: reportedTrackID,
                status: mutationStatusDescription(track.trackStatus)
            )
        }
    }

    func invalidateCaches(for change: ProposedChange) async {
        await BestEffortInvalidator(cache: cache, snapshot: librarySnapshotService).invalidate(
            targets: Self.cacheInvalidationTargets(for: change, cleaning: runtimeConfiguration.cleaning)
        )
    }

    static func cacheInvalidationTargets(
        for change: ProposedChange,
        cleaning: CleaningConfig? = nil
    ) -> [(artist: String, album: String)] {
        var candidates: [AlbumIdentity] = []
        Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: change.track.album)

        if change.changeType == .artistRename, let oldArtist = change.oldValue {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: oldArtist,
                album: change.track.album
            ))
        }
        if change.changeType == .artistRename, let newArtist = change.newValue {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: newArtist,
                album: change.track.album
            ))
        }
        if change.changeType == .albumCleaning, let oldAlbum = change.oldValue {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: oldAlbum)
        }
        if change.changeType == .albumCleaning, let newAlbum = change.newValue {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: newAlbum)
        }
        if let cleaning,
           let cleanedAlbum = Self.cleanedCacheInvalidationAlbum(
               for: change.track,
               cleaning: cleaning
           ) {
            Self.appendCacheInvalidationIdentities(&candidates, for: change.track, album: cleanedAlbum)
        }

        var seenKeys: Set<String> = []
        return candidates.compactMap { identity in
            guard identity.isComplete else { return nil }
            guard seenKeys.insert(identity.key).inserted else { return nil }
            return (artist: identity.artist, album: identity.album)
        }
    }

    private static func appendCacheInvalidationIdentities(
        _ candidates: inout [AlbumIdentity],
        for track: Track,
        album: String
    ) {
        candidates.append(contentsOf: cacheInvalidationIdentities(for: track, album: album))
        if let originalArtist = track.originalArtist {
            candidates.append(contentsOf: AlbumIdentity.lookupCandidates(
                artist: originalArtist,
                album: album
            ))
        }
    }

    private static func cacheInvalidationIdentities(for track: Track, album: String) -> [AlbumIdentity] {
        [
            track.albumIdentity.artist,
            track.effectiveArtist,
            track.artist
        ].flatMap { artist in
            AlbumIdentity.lookupCandidates(artist: artist, album: album)
        }
    }

    private static func cleanedCacheInvalidationAlbum(for track: Track, cleaning: CleaningConfig) -> String? {
        let cleaned = cleanNames(
            artist: track.artist,
            trackName: track.name,
            albumName: track.album,
            config: cleaning
        )
        guard !cleaned.cleanedAlbum.isEmpty,
              normalizedCacheAlbum(cleaned.cleanedAlbum) != normalizedCacheAlbum(track.album)
        else {
            return nil
        }
        return cleaned.cleanedAlbum
    }

    private static func normalizedCacheAlbum(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func mutationStatusDescription(_ status: String?) -> String {
        let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "unknown" }
        return trimmed
    }
}
