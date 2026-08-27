@testable import Core

func repairValidationCases(
    revision: MirrorRevision,
    target: Track,
    occupied: Track,
    other: Track,
    legacy: Track
) -> [(TrackMirrorUpdate, TrackStoreError)] {
    [
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "missing", target: target)],
            upserts: []
        ), .missingSource(id: "missing")),
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "legacy", target: other),
            ], upserts: []
        ), .duplicateRepairSources(ids: ["legacy"])),
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceID: "legacy", target: target),
                TrackMirrorRepair(sourceID: "occupied", target: target),
            ], upserts: []
        ), .duplicateRepairTargets(ids: [testDatabaseID("target")])),
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: occupied)],
            upserts: []
        ), .targetExists(id: testDatabaseID("occupied"))),
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: target)],
            upserts: [target]
        ), .identityOverlap(ids: [testDatabaseID("target")])),
        (TrackMirrorUpdate(
            baseRevision: revision,
            coverageChange: .preserve,
            membershipChange: .preserve,
            repairs: [TrackMirrorRepair(sourceID: "legacy", target: legacy)],
            upserts: []
        ), .redundantRepair(id: testDatabaseID("legacy"))),
    ]
}
