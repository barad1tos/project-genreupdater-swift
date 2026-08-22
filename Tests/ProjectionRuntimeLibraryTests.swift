import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Projection runtime library loading")
@MainActor
struct ProjectionRuntimeLibraryTests {
    @Test("the backend load chain publishes library facts headlessly")
    func backendLoadPublishesLibraryFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant", genre: "Rock", year: 2004),
        ])
        var appliedCounts: [Int] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            appliedCounts.append(tracks.count)
        }
        var browseApplications: [(count: Int, isCurrent: Bool)] = []
        fixture.dependencies.applyBrowseTruthForLoad = { tracks, _, token in
            browseApplications.append((tracks.count, fixture.dependencies.libraryLoadGate.isCurrent(token)))
        }

        await fixture.dependencies.loadLibrary()

        // Facts land on the dependency graph, the projection republishes
        // from the SAME values, and BOTH host callbacks fire with the
        // landed tracks (the PR-A scope-preview ledger pin + the browse
        // application seam).
        #expect(fixture.dependencies.libraryTracks.count == 1)
        let published = await fixture.dependencies.projectionStore.activityProjection()
        #expect(published.healthFacts.counts.totalTracks == 1)
        #expect(appliedCounts == [1])
        let browseCounts = browseApplications.map(\.count)
        let browseAllCurrent = browseApplications.allSatisfy(\.isCurrent)
        #expect(browseCounts == [1])
        #expect(browseAllCurrent)
    }

    @Test("a scope change synchronously empties library truth")
    func scopeChangeEmptiesLibraryTruth() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ])
        await fixture.dependencies.loadLibrary()
        #expect(!fixture.dependencies.libraryTracks.isEmpty)

        fixture.dependencies.invalidateLibraryLoads()
        fixture.dependencies.emptyLibraryTruthForScopeChange()

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.libraryMetrics == nil)
        #expect(fixture.dependencies.lastLibraryScanDate == nil)
        #expect(!fixture.dependencies.isLibraryLoading)
        let republished = await fixture.dependencies.republishActivityProjection()
        #expect(republished.healthFacts.counts.totalTracks == 0)
    }

    @Test("a mid-flight invalidation drops the stale load's facts")
    func inFlightInvalidationDropsStaleFacts() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let gate = LibraryReadGate()
        fixture.dependencies.installTestLibraryReadProvider(GatedProvider(gate: gate))

        let load = Task { await fixture.dependencies.loadLibrary() }
        await gate.waitUntilRequested()
        fixture.dependencies.invalidateLibraryLoads()
        fixture.dependencies.emptyLibraryTruthForScopeChange()
        await gate.release()
        await load.value

        #expect(fixture.dependencies.libraryTracks.isEmpty)
        #expect(fixture.dependencies.lastLibraryScanDate == nil)
    }

    @Test("a workflow-only refresh preserves library truth")
    func workflowOnlyRefreshPreservesLibraryTruth() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ])
        await fixture.dependencies.loadLibrary()

        fixture.dependencies.workflowFactsProvider = {
            ActivityWorkflowFacts(dashboard: .empty, pendingVerification: nil)
        }
        let published = await fixture.dependencies.republishActivityProjection()

        #expect(published.healthFacts.counts.totalTracks == 1)
        #expect(fixture.dependencies.libraryTracks.count == 1)
    }

    @Test("an invalidation during browse application drops late writes")
    func invalidationDuringBrowseApplicationDropsLateWrites() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        fixture.dependencies.installTestLibraryReadProvider(SnapshotProvider())
        fixture.dependencies.applyBrowseTruthForLoad = { _, readSource, _ in
            if case .liveLibrary = readSource {
                fixture.dependencies.invalidateLibraryLoads()
            }
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.lastLibraryScanDate == nil)
        #expect(fixture.dependencies.libraryMetrics == nil)
    }

    @Test("a cancelled live load is not an error")
    func cancelledLiveLoadIsNotAnError() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "cached", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ])
        fixture.dependencies.installTestLibraryReadProvider(CancellingProvider())

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryLoadError == nil)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["cached"])
        #expect(!fixture.dependencies.isLibraryLoading)
    }

    @Test("a live-load failure falls back to cached tracks")
    func loadFailureFallsBackToCachedTracks() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        await fixture.snapshotService.installSnapshot([
            Core.Track(id: "cached", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ])
        fixture.dependencies.installTestLibraryReadProvider(FailingProvider())

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryLoadError != nil)
        #expect(fixture.dependencies.libraryTracks.map(\.id) == ["cached"])
        #expect(!fixture.dependencies.isLibraryLoading)
    }

    @Test("request tokens invalidate across begins")
    func requestTokenGateTruthTable() {
        let gate = RequestTokenGate()

        let first = gate.begin()
        #expect(gate.isCurrent(first))

        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))

        gate.invalidate()
        #expect(!gate.isCurrent(second))
    }
}

private actor LibraryReadGate {
    private var requested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?

    func waitUntilRequested() async {
        if requested {
            return
        }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func hold() async {
        requested = true
        requestContinuation?.resume()
        requestContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor GatedProvider: LibraryReadProvider {
    private let gate: LibraryReadGate

    init(gate: LibraryReadGate) {
        self.gate = gate
    }

    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        await gate.hold()
        return LibraryReadSnapshot(tracks: [
            Core.Track(id: "stale", name: "Old Scope", artist: "Stale", album: "Stale"),
        ], scannedAt: Date(timeIntervalSince1970: 100))
    }
}

actor SnapshotProvider: LibraryReadProvider {
    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        LibraryReadSnapshot(tracks: [
            Core.Track(id: "live", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ], scannedAt: Date(timeIntervalSince1970: 200))
    }
}

private actor CancellingProvider: LibraryReadProvider {
    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        throw CancellationError()
    }
}

private actor FailingProvider: LibraryReadProvider {
    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        throw MusicLibraryError.fetchFailed(detail: "stubbed live failure")
    }
}
