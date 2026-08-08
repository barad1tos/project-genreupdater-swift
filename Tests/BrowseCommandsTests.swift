import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Browse commands")
@MainActor
struct BrowseCommandsTests {
    private let scopeSnapshotID = UUID()

    private func projection(
        revision: ProjectionRevision = .initial,
        actionEnabled: Bool = true
    ) -> BrowseProjection {
        let action = ChromeCommandDescriptor(
            id: "browse-preview-key",
            title: "Preview changes",
            isEnabled: actionEnabled,
            disabledReason: actionEnabled ? nil : "Outside the current Test Artists scope.",
            commandKind: .requestAlbumPreview
        )
        let album = BrowseAlbumNode(
            id: "album-key",
            title: "Blast Tyrant",
            artistName: "Clutch",
            genre: "Rock",
            year: 2004,
            counts: BrowseNodeCounts(total: 12, inScope: actionEnabled ? 12 : 0, writable: 12),
            action: action
        )
        return BrowseProjection(
            revision: revision,
            artists: [BrowseArtistNode(id: "clutch", name: "Clutch", albums: [album])],
            scope: BrowseScopeFacts(
                snapshotID: scopeSnapshotID,
                fingerprint: "test-fingerprint",
                summary: ChromeScopeSummary(
                    sourceLabel: "Test artists (1)",
                    detailLabel: "Clutch",
                    isNarrowedFromPhysical: true
                )
            ),
            physicalTrackCount: nil,
            readSource: .liveLibrary(scannedAt: Date(timeIntervalSince1970: 100)),
            operationalIssues: []
        )
    }

    private func target(
        albumID: String = "album-key",
        revision: ProjectionRevision = .initial,
        scopeID: UUID? = nil
    ) -> BrowseCommandTarget {
        BrowseCommandTarget(
            albumID: albumID,
            projectionRevision: revision,
            scopeSnapshotID: scopeID ?? scopeSnapshotID
        )
    }

    private final class Recorder: @unchecked Sendable {
        var submitted: [FixPlanAlbumTarget] = []
        var republishCount = 0
    }

    private func makeCommands(
        projection: BrowseProjection,
        result: RunSubmissionResult = .recoveryRequired,
        shouldThrow: Bool = false,
        recorder: Recorder
    ) -> BrowseCommands {
        BrowseCommands(
            currentBrowse: { projection },
            submitAlbumPreview: { target in
                recorder.submitted.append(target)
                if shouldThrow {
                    throw BrowseCommandsTestError.intentional
                }
                return result
            },
            republishBrowse: { recorder.republishCount += 1 }
        )
    }

    @Test("a stale projection revision rejects and republishes")
    func staleRevisionRejects() async {
        let recorder = Recorder()
        let commands = makeCommands(projection: projection(revision: ProjectionRevision(7)), recorder: recorder)

        let status = await commands.performAlbumPreview(target: target(revision: .initial))

        #expect(status == .rejectedStale)
        #expect(recorder.republishCount == 1)
        #expect(recorder.submitted.isEmpty)
    }

    @Test("a changed scope snapshot rejects and republishes")
    func changedScopeRejects() async {
        let recorder = Recorder()
        let commands = makeCommands(projection: projection(), recorder: recorder)

        let status = await commands.performAlbumPreview(target: target(scopeID: UUID()))

        #expect(status == .rejectedStale)
        #expect(recorder.republishCount == 1)
        #expect(recorder.submitted.isEmpty)
    }

    @Test("a vanished album rejects as invalid")
    func missingAlbumRejects() async {
        let recorder = Recorder()
        let commands = makeCommands(projection: projection(), recorder: recorder)

        let status = await commands.performAlbumPreview(target: target(albumID: "gone"))

        #expect(status == .rejectedInvalid)
        #expect(recorder.republishCount == 1)
        #expect(recorder.submitted.isEmpty)
    }

    @Test("a disabled album action rejects without submitting")
    func disabledActionRejects() async {
        let recorder = Recorder()
        let commands = makeCommands(projection: projection(actionEnabled: false), recorder: recorder)

        let status = await commands.performAlbumPreview(target: target())

        #expect(status == .rejectedInvalid)
        #expect(recorder.republishCount == 1)
        #expect(recorder.submitted.isEmpty)
    }

    @Test("a scope-less projection fails closed")
    func nilScopeRejects() async {
        // BrowseProjection.empty() is a real nil-scope state; a command
        // against it must never reach submission.
        let base = projection()
        let scopeless = BrowseProjection(
            revision: base.revision,
            artists: base.artists,
            scope: nil,
            physicalTrackCount: nil,
            readSource: nil,
            operationalIssues: []
        )
        let recorder = Recorder()
        let commands = makeCommands(projection: scopeless, recorder: recorder)

        let status = await commands.performAlbumPreview(target: target())

        #expect(status == .rejectedStale)
        #expect(recorder.republishCount == 1)
        #expect(recorder.submitted.isEmpty)
    }

    @Test("a valid request submits the node's display identity")
    func validRequestSubmits() async {
        let recorder = Recorder()
        let commands = makeCommands(
            projection: projection(),
            result: .completedNoOp(makeLifecycleSnapshot()),
            recorder: recorder
        )

        let status = await commands.performAlbumPreview(target: target())

        #expect(status == .noOp)
        #expect(recorder.submitted == [FixPlanAlbumTarget(artist: "Clutch", album: "Blast Tyrant")])
        #expect(recorder.republishCount == 0)
    }

    @Test("submission outcomes map onto the typed status vocabulary")
    func outcomeMapping() async {
        let snapshot = makeLifecycleSnapshot()
        let cases: [(RunSubmissionResult, CommandResultStatus)] = [
            (.completed(snapshot), .accepted),
            (.queued(activeRun: snapshot), .queued),
            (.alreadyCovered(activeRun: snapshot), .alreadyCovered),
            (.cancelled(snapshot), .noOp),
            (.recoveryRequired, .blockedByRecovery),
            (.recoverable(snapshot, reason: "io"), .blockedByRecovery),
            (.failed(snapshot), .requiresAttention),
        ]

        for (result, expected) in cases {
            let recorder = Recorder()
            let commands = makeCommands(projection: projection(), result: result, recorder: recorder)
            let status = await commands.performAlbumPreview(target: target())
            #expect(status == expected)
        }
    }

    @Test("a submission failure maps to temporary unavailability")
    func submissionThrowMaps() async {
        let recorder = Recorder()
        let commands = makeCommands(projection: projection(), shouldThrow: true, recorder: recorder)

        let status = await commands.performAlbumPreview(target: target())

        #expect(status == .temporaryUnavailable)
        #expect(recorder.submitted.count == 1)
        // A transport failure is not a staleness rejection: the shown
        // projection is still true, so no republish fires.
        #expect(recorder.republishCount == 0)
    }
}

private enum BrowseCommandsTestError: Error {
    case intentional
}

private func makeLifecycleSnapshot() -> RunLifecycleSnapshot {
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    return RunLifecycleSnapshot(
        runID: RunID(),
        requestID: RunRequestID(),
        trigger: .manualCheck,
        intent: .previewFixes,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: startedAt,
            reason: "browse-commands-test"
        ),
        startedAt: startedAt,
        phase: .active(.created)
    )
}
