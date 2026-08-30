import Core
import Foundation
import Testing
@testable import Services

@Suite("Mirror effect batch drain")
struct MirrorEffectBatchTests {
    @Test("Older global effects complete before a newer scoped failure")
    func preservesBacklogOrder() async throws {
        let olderSnapshotID = UUID()
        let olderProjectionID = UUID()
        let newerAlbumID = UUID()
        let newerSnapshotID = UUID()
        let newerProjectionID = UUID()
        let identity = AlbumIdentity(artist: "In Flames", album: "Foregone")
        let effects = [
            PendingMirrorEffect(
                id: olderSnapshotID,
                revision: MirrorRevision(value: 6),
                sequence: 0,
                effect: .invalidateSnapshot
            ),
            PendingMirrorEffect(
                id: olderProjectionID,
                revision: MirrorRevision(value: 6),
                sequence: 1,
                effect: .refreshProjections
            ),
            PendingMirrorEffect(
                id: newerAlbumID,
                revision: MirrorRevision(value: 7),
                sequence: 0,
                effect: .invalidateAlbumYear(identity)
            ),
            PendingMirrorEffect(
                id: newerSnapshotID,
                revision: MirrorRevision(value: 7),
                sequence: 1,
                effect: .invalidateSnapshot
            ),
            PendingMirrorEffect(
                id: newerProjectionID,
                revision: MirrorRevision(value: 7),
                sequence: 2,
                effect: .refreshProjections
            ),
        ]
        let store = EffectStore(pending: effects)
        let snapshot = EffectSnapshot()
        let projections = ProjectionRecorder()
        let drain = MirrorEffectDrain(
            store: store,
            cache: EffectCache(failingOperation: .albumYear),
            snapshot: snapshot,
            projections: projections
        )

        await drain.drainBatchEffects()

        #expect(await snapshot.clearCount == 1)
        #expect(await projections.refreshCount == 1)
        #expect(await store.completedEffectIDs() == [olderSnapshotID, olderProjectionID])
        #expect(try await store.pendingMirrorEffects().map(\.id) == [
            newerAlbumID,
            newerSnapshotID,
            newerProjectionID,
        ])
    }

    @Test("Global effects coalesce without dropping scoped invalidations")
    func coalescesGlobals() async throws {
        let firstIdentity = AlbumIdentity(artist: "In Flames", album: "Battles")
        let secondIdentity = AlbumIdentity(artist: "In Flames", album: "Foregone")
        let effects = [
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 6),
                sequence: 0,
                effect: .invalidateAlbumYear(firstIdentity)
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 6),
                sequence: 1,
                effect: .invalidateSnapshot
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 6),
                sequence: 2,
                effect: .refreshProjections
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 7),
                sequence: 0,
                effect: .invalidateAlbumYear(secondIdentity)
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 7),
                sequence: 1,
                effect: .invalidateSnapshot
            ),
            PendingMirrorEffect(
                id: UUID(),
                revision: MirrorRevision(value: 7),
                sequence: 2,
                effect: .refreshProjections
            ),
        ]
        let store = EffectStore(pending: effects)
        let cache = EffectCache()
        let snapshot = EffectSnapshot()
        let projections = ProjectionRecorder()
        let drain = MirrorEffectDrain(
            store: store,
            cache: cache,
            snapshot: snapshot,
            projections: projections
        )

        await drain.drainBatchEffects()

        let completedIDs = await store.completedEffectIDs()
        #expect(await cache.operations == [
            .albumYear(artist: firstIdentity.artist, album: firstIdentity.album),
            .albumYear(artist: secondIdentity.artist, album: secondIdentity.album),
        ])
        #expect(await snapshot.clearCount == 1)
        #expect(await projections.refreshCount == 1)
        #expect(Set(completedIDs) == Set(effects.map(\.id)))
        #expect(try await store.pendingMirrorEffects().isEmpty)
    }
}
