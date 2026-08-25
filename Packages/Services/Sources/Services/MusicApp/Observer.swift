import Core
import Foundation

protocol ObservationSource: Actor {
    func fetchCensus() async throws -> TrackIDCensus
    func fetchMetadata(for ids: [MusicDatabaseTrackID]) async throws -> [Track]
}

extension AppleScriptBridge: ObservationSource {}

/// AppleScript-backed processing observer with no catalog or mutation capabilities.
public actor MusicAppObserver: MusicAppReading {
    private let source: any ObservationSource

    public init(bridge: AppleScriptBridge) {
        self.init(source: bridge)
    }

    init(source: any ObservationSource) {
        self.source = source
    }

    public func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        let startedCensus = try await source.fetchCensus()
        let requestedIDs = metadataIDs(for: startedCensus.ids, request: request)
        let sourceTracks = requestedIDs.isEmpty ? [] : try await source.fetchMetadata(for: requestedIDs)
        let endedCensus = try await source.fetchCensus()

        guard endedCensus.generation == startedCensus.generation else {
            throw MusicAppObservationError.generationChanged(
                started: startedCensus.generation,
                ended: endedCensus.generation
            )
        }
        guard endedCensus == startedCensus else {
            throw MusicAppObservationError.censusChanged
        }

        let rowsByID = try normalize(sourceTracks, requestedIDs: Set(requestedIDs))
        let observedIDs = Set(rowsByID.keys)
        let missingIDs = Set(requestedIDs).subtracting(observedIDs)
        let scoped = scopedResult(
            censusIDs: Set(startedCensus.ids),
            rowsByID: rowsByID,
            missingIDs: missingIDs,
            request: request
        )
        let orderedRows = requestedIDs.compactMap { rowsByID[$0] }.filter(scoped.includes)

        return LibraryObservation(
            tracks: orderedRows,
            censusIDs: Set(startedCensus.ids),
            currentIDs: scoped.currentIDs,
            scope: request.scope,
            observedAt: Date(),
            membership: scoped.membership,
            metadata: MetadataCompleteness(requestedIDs: Set(requestedIDs), observedIDs: observedIDs),
            generation: startedCensus.generation,
            issues: missingIDs.sorted { $0.rawValue < $1.rawValue }.map {
                .metadataUnobserved(databaseID: $0, detail: "Metadata lookup returned no row")
            }
        )
    }

    private func metadataIDs(
        for censusIDs: [MusicDatabaseTrackID],
        request: LibraryObservationRequest
    ) -> [MusicDatabaseTrackID] {
        switch request.refresh {
        case .fast:
            let previousIDs = Set(request.previous.tracksByID.keys)
            return censusIDs.filter { !previousIDs.contains($0) }
        case .force:
            return censusIDs
        case .membershipOnly:
            return []
        }
    }

    private func normalize(
        _ tracks: [Track],
        requestedIDs: Set<MusicDatabaseTrackID>
    ) throws -> [MusicDatabaseTrackID: LibraryTrackRow] {
        var rowsByID = [MusicDatabaseTrackID: LibraryTrackRow]()
        for track in tracks {
            guard let databaseID = track.databaseID else {
                throw MusicAppObservationError.unresolvedMetadataIdentity
            }
            guard requestedIDs.contains(databaseID) else {
                throw MusicAppObservationError.unexpectedMetadata(databaseID)
            }
            guard rowsByID.updateValue(Self.row(from: track, databaseID: databaseID), forKey: databaseID) == nil
            else {
                throw MusicAppObservationError.duplicateMetadata(databaseID)
            }
        }
        return rowsByID
    }

    private func scopedResult(
        censusIDs: Set<MusicDatabaseTrackID>,
        rowsByID: [MusicDatabaseTrackID: LibraryTrackRow],
        missingIDs: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) -> ScopedResult {
        guard request.scope.source == .testArtists else {
            return ScopedResult(currentIDs: censusIDs, membership: .full, includes: { _ in true })
        }

        let currentPreviousIDs = Set<MusicDatabaseTrackID>(request.previous.tracksByID.compactMap { databaseID, track in
            guard censusIDs.contains(databaseID),
                  ArtistAllowList.containsNormalized(track, in: request.scope.normalizedTestArtists)
            else { return nil }
            return databaseID
        })
        let observedScopedIDs = Set(rowsByID.compactMap { databaseID, row in
            row.matches(request.scope) ? databaseID : nil
        })
        let previousIDs = request.refresh == .force ? [] : currentPreviousIDs
        let unobservedIDs = request.refresh == .membershipOnly
            ? censusIDs.subtracting(currentPreviousIDs)
            : missingIDs
        return ScopedResult(
            currentIDs: previousIDs.union(observedScopedIDs),
            membership: .scoped(unobservedIDs: unobservedIDs),
            includes: { $0.matches(request.scope) }
        )
    }

    private static func row(from track: Track, databaseID: MusicDatabaseTrackID) -> LibraryTrackRow {
        LibraryTrackRow(
            databaseID: databaseID,
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: observed(track.name),
                    artist: observed(track.artist),
                    album: observed(track.album),
                    albumArtist: observed(track.albumArtist)
                ),
                genre: observed(track.genre),
                editableYear: observed(track.year),
                releaseYear: observed(track.releaseYear),
                dateAdded: observed(track.dateAdded),
                lastModified: observed(track.lastModified),
                status: observed(track.trackStatus)
            )
        )
    }

    private static func observed(_ value: String?) -> Observed<String> {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .absent
        }
        return .value(value)
    }

    private static func observed<Value: Sendable>(_ value: Value?) -> Observed<Value> {
        value.map(Observed.value) ?? .absent
    }
}

private struct ScopedResult {
    let currentIDs: Set<MusicDatabaseTrackID>
    let membership: MembershipCompleteness
    let includes: (LibraryTrackRow) -> Bool
}
