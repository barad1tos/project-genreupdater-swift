import Core
import Foundation

protocol ObservationSource: Actor {
    func fetchCensus() async throws -> TrackIDCensus
    func fetchIdentity(for ids: [MusicDatabaseTrackID]) async throws -> [LibraryIdentityRow]
    func fetchMetadata(for ids: [MusicDatabaseTrackID]) async throws -> [Track]
}

extension AppleScriptBridge: ObservationSource {}

/// AppleScript-backed processing observer with no catalog or mutation capabilities.
public actor MusicAppObserver: MusicAppReading {
    private let source: any ObservationSource

    private struct IdentityLane {
        let requestedIDs: [MusicDatabaseTrackID]
        let rowsByID: [MusicDatabaseTrackID: LibraryIdentityRow]
    }

    private struct MetadataLane {
        let requestedIDs: [MusicDatabaseTrackID]
        let rowsByID: [MusicDatabaseTrackID: LibraryTrackRow]
    }

    public init(bridge: AppleScriptBridge) {
        self.init(source: bridge)
    }

    init(source: any ObservationSource) {
        self.source = source
    }

    public func observe(_ request: LibraryObservationRequest) async throws -> LibraryObservation {
        let startedCensus = try await source.fetchCensus()
        let censusIDs = Set(startedCensus.ids)
        let identity = try await observeIdentity(censusIDs: startedCensus.ids, request: request)
        let admittedIDs = request.inventory.admittedIDs(
            censusIDs: censusIDs,
            observed: identity.rowsByID,
            scope: request.scope
        )
        let metadata = try await observeMetadata(
            censusIDs: startedCensus.ids,
            admittedIDs: admittedIDs,
            request: request
        )
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

        return assembleObservation(
            census: startedCensus,
            identity: identity,
            metadata: metadata,
            admittedIDs: admittedIDs,
            request: request
        )
    }

    private func observeIdentity(
        censusIDs: [MusicDatabaseTrackID],
        request: LibraryObservationRequest
    ) async throws -> IdentityLane {
        let requestedIdentityIDs = identityIDs(for: censusIDs, request: request)
        let sourceIdentities = requestedIdentityIDs.isEmpty
            ? []
            : try await source.fetchIdentity(for: requestedIdentityIDs)
        let observedIdentities = try normalizeIdentities(
            sourceIdentities,
            requestedIDs: Set(requestedIdentityIDs)
        )
        return IdentityLane(requestedIDs: requestedIdentityIDs, rowsByID: observedIdentities)
    }

    private func observeMetadata(
        censusIDs: [MusicDatabaseTrackID],
        admittedIDs: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) async throws -> MetadataLane {
        let requestedMetadataIDs = metadataIDs(
            for: censusIDs,
            admittedIDs: admittedIDs,
            request: request
        )
        let sourceTracks = requestedMetadataIDs.isEmpty
            ? []
            : try await source.fetchMetadata(for: requestedMetadataIDs)
        let rowsByID = try normalize(sourceTracks, requestedIDs: Set(requestedMetadataIDs))
        return MetadataLane(requestedIDs: requestedMetadataIDs, rowsByID: rowsByID)
    }

    private func assembleObservation(
        census: TrackIDCensus,
        identity: IdentityLane,
        metadata: MetadataLane,
        admittedIDs: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) -> LibraryObservation {
        let censusIDs = Set(census.ids)
        let observedMetadataIDs = Set(metadata.rowsByID.keys)
        let missingMetadataIDs = Set(metadata.requestedIDs).subtracting(observedMetadataIDs)
        let derivedIdentities = request.scope.source == .fullLibrary
            ? Dictionary(uniqueKeysWithValues: metadata.rowsByID.map { ($0.key, $0.value.identityRow) })
            : identity.rowsByID
        let identityRequestedIDs = request.scope.source == .fullLibrary
            ? Set(metadata.requestedIDs)
            : Set(identity.requestedIDs)
        let observedIdentityIDs = Set(derivedIdentities.keys)
        let missingIdentityIDs = identityRequestedIDs.subtracting(observedIdentityIDs)
        let orderedRows = metadata.requestedIDs.compactMap { metadata.rowsByID[$0] }
        let orderedIdentities = census.ids.compactMap { derivedIdentities[$0] }
        let membership = membershipCompleteness(
            scope: request.scope,
            missingIdentityIDs: missingIdentityIDs
        )

        return LibraryObservation(
            tracks: orderedRows,
            identities: orderedIdentities,
            censusIDs: censusIDs,
            currentIDs: admittedIDs,
            scope: request.scope,
            observedAt: Date(),
            membership: membership,
            identity: IdentityCompleteness(
                requestedIDs: identityRequestedIDs,
                observedIDs: observedIdentityIDs
            ),
            metadata: MetadataCompleteness(
                requestedIDs: Set(metadata.requestedIDs),
                observedIDs: observedMetadataIDs
            ),
            generation: census.generation,
            issues: scopedIdentityIssues(for: missingIdentityIDs, request: request)
                + metadataIssues(for: missingMetadataIDs)
        )
    }

    private func identityIDs(
        for censusIDs: [MusicDatabaseTrackID],
        request: LibraryObservationRequest
    ) -> [MusicDatabaseTrackID] {
        guard request.scope.source == .testArtists else { return [] }
        switch request.refresh {
        case .force:
            return censusIDs
        case .fast, .membershipOnly:
            let classifiedIDs = Set(request.inventory.identitiesByID.keys)
            return censusIDs.filter { !classifiedIDs.contains($0) }
        }
    }

    private func metadataIDs(
        for censusIDs: [MusicDatabaseTrackID],
        admittedIDs: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) -> [MusicDatabaseTrackID] {
        switch request.refresh {
        case .fast:
            let previousIDs = Set(request.previous.tracksByID.keys)
            return censusIDs.filter { admittedIDs.contains($0) && !previousIDs.contains($0) }
        case .force:
            return censusIDs.filter(admittedIDs.contains)
        case .membershipOnly:
            return []
        }
    }

    private func normalizeIdentities(
        _ identities: [LibraryIdentityRow],
        requestedIDs: Set<MusicDatabaseTrackID>
    ) throws -> [MusicDatabaseTrackID: LibraryIdentityRow] {
        var rowsByID = [MusicDatabaseTrackID: LibraryIdentityRow]()
        for identity in identities {
            guard requestedIDs.contains(identity.databaseID) else {
                throw MusicAppObservationError.unexpectedIdentity(identity.databaseID)
            }
            guard rowsByID.updateValue(identity, forKey: identity.databaseID) == nil else {
                throw MusicAppObservationError.duplicateIdentity(identity.databaseID)
            }
        }
        return rowsByID
    }

    private func membershipCompleteness(
        scope: ProcessingScopeSnapshot,
        missingIdentityIDs: Set<MusicDatabaseTrackID>
    ) -> MembershipCompleteness {
        scope.source == .fullLibrary ? .full : .scoped(unobservedIDs: missingIdentityIDs)
    }

    private func scopedIdentityIssues(
        for ids: Set<MusicDatabaseTrackID>,
        request: LibraryObservationRequest
    ) -> [LibraryObservationIssue] {
        guard request.scope.source == .testArtists else { return [] }
        return ids.sorted { $0.rawValue < $1.rawValue }.map {
            LibraryObservationIssue.identityUnobserved(
                databaseID: $0,
                detail: "Identity lookup returned no row"
            )
        }
    }

    private func metadataIssues(for ids: Set<MusicDatabaseTrackID>) -> [LibraryObservationIssue] {
        ids.sorted { $0.rawValue < $1.rawValue }.map {
            .metadataUnobserved(databaseID: $0, detail: "Metadata lookup returned no row")
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
