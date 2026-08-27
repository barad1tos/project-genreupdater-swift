@testable import Core

func repairValidationCases(
    revision: MirrorRevision,
    target: Track,
    occupied: Track,
    other: Track,
    legacy: Track
) -> [(MirrorCommit, TrackStoreError)] {
    [
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "missing", target: target)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .missingSource(id: "missing")),
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "legacy", target: other),
            ], upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .duplicateRepairSources(ids: ["legacy"])),
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "occupied", target: target),
            ], upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .duplicateRepairTargets(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: occupied)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .targetExists(id: testDatabaseID("occupied"))),
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: target)],
            upserts: [target],
            certificates: .invalidate(.incompleteObservation)
        ), .identityOverlap(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: legacy)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .redundantRepair(id: testDatabaseID("legacy"))),
    ]
}
