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
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "missing", target: target)],
            upserts: []
        ), .missingSource(id: "missing")),
        (MirrorCommit(
            baseRevision: revision,
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "legacy", target: other),
            ], upserts: []
        ), .duplicateRepairSources(ids: ["legacy"])),
        (MirrorCommit(
            baseRevision: revision,
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "occupied", target: target),
            ], upserts: []
        ), .duplicateRepairTargets(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: occupied)],
            upserts: []
        ), .targetExists(id: testDatabaseID("occupied"))),
        (MirrorCommit(
            baseRevision: revision,
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: target)],
            upserts: [target]
        ), .identityOverlap(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            certificates: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: legacy)],
            upserts: []
        ), .redundantRepair(id: testDatabaseID("legacy"))),
    ]
}
