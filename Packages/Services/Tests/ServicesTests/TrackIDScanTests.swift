import Core
import Testing
@testable import Services

@Suite("Track ID scan")
struct TrackIDScanTests {
    @Test("Rejects forged census completeness")
    func rejectsMalformedCensus() throws {
        let firstID = try #require(MusicDatabaseTrackID(rawValue: "1"))
        let secondID = try #require(MusicDatabaseTrackID(rawValue: "2"))
        let generation = try #require(LibraryGeneration(sourceValue: "G1"))

        #expect(throws: TrackIDCensusError.countMismatch(expected: 2, actual: 1)) {
            _ = try TrackIDCensus(ids: [firstID], totalCount: 2, generation: generation)
        }
        #expect(throws: TrackIDCensusError.duplicateID(firstID)) {
            _ = try TrackIDCensus(ids: [firstID, firstID], totalCount: 2, generation: generation)
        }
        #expect(throws: TrackIDCensusError.unsorted) {
            _ = try TrackIDCensus(ids: [secondID, firstID], totalCount: 2, generation: generation)
        }
    }

    @Test("Returns a sorted typed census from one bulk response")
    func returnsBulkCensus() async throws {
        let scan = TrackIDScan(timeout: .seconds(1)) { remaining in
            #expect(remaining > .zero && remaining <= .seconds(1))
            return "CENSUS:3:G1:20,10,30"
        }

        let census = try await scan.run()

        #expect(census.ids.map(\.rawValue) == ["10", "20", "30"])
        #expect(census.totalCount == 3)
        #expect(census.generation.rawValue == "G1")
    }

    @Test("Accepts an empty library census")
    func acceptsEmptyLibrary() async throws {
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            "CENSUS:0:G1:"
        }

        let census = try await scan.run()

        #expect(census.ids.isEmpty)
        #expect(census.totalCount == 0)
        #expect(census.generation.rawValue == "G1")
    }

    @Test("Rejects a declared count that does not match the payload")
    func rejectsCountMismatch() async {
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            "CENSUS:3:G1:10,20"
        }

        await expectParseError(from: scan, containing: "count does not match")
    }

    @Test("Rejects duplicate database IDs")
    func rejectsDuplicateIDs() async {
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            "CENSUS:2:G1:10,10"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected duplicate IDs to be rejected")
        } catch let error as TrackIDCensusError {
            guard case let .duplicateID(databaseID) = error else {
                Issue.record("Expected duplicateID, got \(error)")
                return
            }
            #expect(databaseID.rawValue == "10")
        } catch {
            Issue.record("Expected TrackIDCensusError, got \(error)")
        }
    }

    @Test("Rejects a non-numeric Music database ID")
    func rejectsMalformedID() async {
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            "CENSUS:2:G1:10,missing value"
        }

        await expectParseError(from: scan, containing: "invalid database ID")
    }

    @Test("Rejects a response returned after the scan deadline")
    func rejectsLateResponse() async {
        let scan = TrackIDScan(timeout: .milliseconds(5)) { _ in
            try await Task.sleep(for: .milliseconds(30))
            return "CENSUS:1:G1:10"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected the scan deadline to expire")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Restarts after the producer reports a generation change")
    func restartsAfterGenerationChange() async throws {
        let responses = CensusResponses([
            "RETRY:GENERATION",
            "CENSUS:2:G2:10,20",
        ])
        let scan = TrackIDScan(timeout: .seconds(1)) { remaining in
            await responses.next(remaining: remaining)
        }

        let census = try await scan.run()

        #expect(census.ids.map(\.rawValue) == ["10", "20"])
        #expect(census.generation.rawValue == "G2")
        #expect(await responses.remainingBudgets.count == 2)
    }

    @Test("Preserves one timeout budget across a generation restart")
    func preservesTimeoutAfterRestart() async {
        let calls = CensusCallLog()
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            if await calls.record() == 1 {
                return "RETRY:GENERATION"
            }
            throw AppleScriptBridgeError.timeout(scriptName: "fetch_track_ids", duration: .seconds(1))
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected the restarted scan to time out")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Limits repeated generation restarts")
    func limitsGenerationRestarts() async {
        let calls = CensusCallLog()
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
            _ = await calls.record()
            return "RETRY:GENERATION"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected repeated generation changes to fail")
        } catch let error as AppleScriptBridgeError {
            guard case .libraryChanged = error else {
                Issue.record("Expected libraryChanged, got \(error)")
                return
            }
            #expect(await calls.count == 4)
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    private func expectParseError(from scan: TrackIDScan, containing expectedDetail: String) async {
        do {
            _ = try await scan.run()
            Issue.record("Expected the census response to be rejected")
        } catch let error as AppleScriptBridgeError {
            guard case let .parseError(scriptName, detail) = error else {
                Issue.record("Expected parseError, got \(error)")
                return
            }
            #expect(scriptName == "fetch_track_ids")
            #expect(detail.contains(expectedDetail))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }
}

private actor CensusCallLog {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}

private actor CensusResponses {
    private var responses: [String]
    private(set) var remainingBudgets: [Duration] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next(remaining: Duration) -> String? {
        remainingBudgets.append(remaining)
        return responses.isEmpty ? nil : responses.removeFirst()
    }
}
