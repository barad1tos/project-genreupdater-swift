import DesignUI
import Testing

@Suite("Shared update result model")
struct UpdateResultModelTests {
    @Test("preview and write snapshots expose only their valid review authority")
    func separatesReviewAuthority() {
        let preview = makeSnapshot(mode: .preview, status: .ready)
        let write = makeSnapshot(mode: .write, status: .completed)

        #expect(preview.canReview)
        #expect(!write.canReview)
    }

    @Test("write rows cannot expose review verdicts")
    func separatesRowState() {
        #expect(UpdateResultChangeState.applied.verdict == nil)
        #expect(UpdateResultChangeState.proposed(.accepted).verdict == .accepted)
    }

    @Test("content details and secondary action icon use defaults")
    func preservesPresentationDefaults() throws {
        let snapshot = makeSnapshot(mode: .preview, status: .ready)
        let track = try #require(snapshot.albums.first?.tracks.first)

        #expect(snapshot.details.isEmpty)
        #expect(track.details.isEmpty)
        #expect(snapshot.secondaryActionIcon == "arrow.counterclockwise")
    }

    private func makeSnapshot(mode: UpdateResultMode, status: UpdateResultStatus) -> UpdateResultSnapshot {
        makeSnapshot(
            mode: mode,
            status: status,
            tracks: [makeTrack(id: "track", state: mode == .preview ? .ready : .applied)]
        )
    }

    private func makeSnapshot(
        mode: UpdateResultMode,
        status: UpdateResultStatus,
        tracks: [UpdateResultTrack]
    ) -> UpdateResultSnapshot {
        UpdateResultSnapshot(
            mode: mode,
            status: status,
            title: "Update results",
            subtitle: "Review metadata changes",
            scope: "Test artists",
            content: .init(
                metrics: [
                    UpdateResultMetric(id: "changes", label: "Changes", value: "1", tone: .accent)
                ],
                albums: [
                    UpdateResultAlbum(
                        id: "album",
                        title: "Björk — Homogenic",
                        tracks: tracks
                    )
                ],
                notices: [
                    UpdateResultNotice(id: "notice", title: "Ready", message: "One change", tone: .info)
                ],
                contentAccess: .available
            ),
            actions: .init(primaryLabel: "Apply", secondaryLabel: "Reject all")
        )
    }

    private func makeTrack(id: String, state: UpdateResultTrackState) -> UpdateResultTrack {
        let changeState: UpdateResultChangeState = switch state {
        case .ready: .proposed(.accepted)
        case .applied: .applied
        case .noChange: .noChange
        case .skipped: .skipped
        case let .failed(message): .failed(message: message)
        }

        return UpdateResultTrack(
            id: id,
            title: "Jóga",
            artist: "Björk",
            state: state,
            changes: [
                UpdateResultChange(
                    id: "change-\(id)",
                    type: .genre,
                    oldValue: "Electronic",
                    newValue: "Art Pop",
                    source: "Discogs",
                    confidence: 0.94,
                    state: changeState
                )
            ]
        )
    }
}
