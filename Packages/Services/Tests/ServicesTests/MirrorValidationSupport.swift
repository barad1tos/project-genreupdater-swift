@testable import Core

func repairValidationCases(
    revision: MirrorRevision,
    target: Track,
    occupied: Track,
    other: Track,
    legacy: Track
) -> [(MirrorCommit, TrackStoreError)] {
    structuralRepairCases(revision: revision, target: target, other: other)
        + storedRepairCases(revision: revision, target: target, occupied: occupied, legacy: legacy)
}

private func structuralRepairCases(
    revision: MirrorRevision,
    target: Track,
    other: Track
) -> [(MirrorCommit, TrackStoreError)] {
    [
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceIDs: ["legacy"], target: target),
                TrackMirrorRepair(sourceIDs: ["legacy"], target: other),
            ], upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .duplicateRepairSources(ids: ["legacy"])),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [
                TrackMirrorRepair(sourceIDs: ["legacy"], target: target),
                TrackMirrorRepair(sourceIDs: ["occupied"], target: target),
            ], upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .duplicateRepairTargets(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [TrackMirrorRepair(sourceIDs: ["legacy"], target: target)],
            upserts: [target],
            certificates: .invalidate(.incompleteObservation)
        ), .identityOverlap(ids: [testDatabaseID("target")])),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [],
            retiredAliasIDs: ["target"],
            upserts: [target],
            certificates: .invalidate(.incompleteObservation)
        ), .identityOverlap(ids: [testDatabaseID("target")])),
    ]
}

private func storedRepairCases(
    revision: MirrorRevision,
    target: Track,
    occupied: Track,
    legacy: Track
) -> [(MirrorCommit, TrackStoreError)] {
    [
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [TrackMirrorRepair(sourceIDs: ["missing"], target: target)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .missingSource(id: "missing")),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [TrackMirrorRepair(sourceIDs: ["legacy"], target: occupied)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .targetExists(id: testDatabaseID("occupied"))),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [TrackMirrorRepair(sourceIDs: ["legacy"], target: legacy)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .redundantRepair(id: testDatabaseID("legacy"))),
        (MirrorCommit(
            baseRevision: revision,
            inventoryChange: .preserve,
            repairs: [TrackMirrorRepair(sourceIDs: ["legacy"], target: target)],
            upserts: [],
            certificates: .invalidate(.incompleteObservation)
        ), .nonLegacyRepairSources(ids: ["legacy"])),
    ]
}
