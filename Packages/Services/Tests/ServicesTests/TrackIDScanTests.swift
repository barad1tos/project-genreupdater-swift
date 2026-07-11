import Testing
@testable import Services

@Suite("Track ID scan")
struct TrackIDScanTests {
    @Test("Collects every ID across bounded batches")
    func collectsBatches() async throws {
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, limit, _ in
            #expect(limit == 2)
            switch offset {
            case 1:
                return "BATCH:2:3:G1:10,20"
            case 3:
                return "BATCH:3:3:G1:30"
            default:
                return nil
            }
        }

        #expect(try await scan.run() == ["10", "20", "30"])
    }

    @Test("Clamps batch limits", arguments: [0, 5000])
    func clampsBatchLimit(_ batchSize: Int) async throws {
        let expectedLimit = batchSize == 0 ? 1 : 1000
        let scan = TrackIDScan(batchSize: batchSize, timeout: .seconds(1)) { _, limit, _ in
            #expect(limit == expectedLimit)
            return "BATCH:1:1:G1:A"
        }

        #expect(try await scan.run() == ["A"])
    }

    @Test("Rejects a track count change between batches")
    func rejectsCountChange() async {
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            offset == 1 ? "BATCH:2:3:G1:10,20" : "BATCH:4:4:G1:30,40"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected the changing library to be rejected")
        } catch let error as AppleScriptBridgeError {
            guard case .libraryChanged = error else {
                Issue.record("Expected libraryChanged, got \(error)")
                return
            }
            #expect(!AppleScriptBridge.isRetryable(error))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Rejects duplicate IDs across batches")
    func rejectsDuplicateIDs() async {
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            offset == 1 ? "BATCH:2:3:G1:10,20" : "BATCH:3:3:G1:20"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected duplicate IDs to be rejected")
        } catch let error as AppleScriptBridgeError {
            guard case .libraryChanged = error else {
                Issue.record("Expected libraryChanged, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Accepts an empty library batch")
    func acceptsEmptyLibrary() async throws {
        let scan = TrackIDScan(batchSize: 10, timeout: .seconds(1)) { _, _, _ in
            "BATCH:0:0:G1:"
        }

        #expect(try await scan.run().isEmpty)
    }

    @Test("Rejects a batch returned after the scan deadline")
    func rejectsLateBatch() async {
        let scan = TrackIDScan(batchSize: 10, timeout: .milliseconds(5)) { _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return "BATCH:1:1:G1:10"
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

    @Test("Restarts after a same-count mutation")
    func restartsAfterMutation() async throws {
        let responses = ScanResponses([
            "BATCH:2:4:G1:A,B",
            "BATCH:4:4:G2:D,E",
            "BATCH:2:4:G3:B,C",
            "BATCH:4:4:G3:D,E",
        ])
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            await responses.next(offset: offset)
        }

        #expect(try await scan.run() == ["B", "C", "D", "E"])
        #expect(await responses.offsets == [1, 3, 1, 3])
    }

    @Test("Restarts when count and generation change together")
    func restartsAfterCountChange() async throws {
        let responses = ScanResponses([
            "BATCH:2:3:G1:A,B",
            "BATCH:4:4:G2:C,D",
            "BATCH:2:4:G3:A,B",
            "BATCH:4:4:G3:C,D",
        ])
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            await responses.next(offset: offset)
        }

        #expect(try await scan.run() == ["A", "B", "C", "D"])
        #expect(await responses.offsets == [1, 3, 1, 3])
    }

    @Test("Limits repeated mutation restarts")
    func limitsMutationRestarts() async {
        let offsets = OffsetLog()
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            let call = await offsets.record(offset)
            let generation = "G\(call)"
            return offset == 1
                ? "BATCH:2:4:\(generation):A,B"
                : "BATCH:4:4:\(generation):C,D"
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected repeated generation changes to fail")
        } catch let error as AppleScriptBridgeError {
            guard case .libraryChanged = error else {
                Issue.record("Expected libraryChanged, got \(error)")
                return
            }
            let recordedOffsets = await offsets.values
            #expect(recordedOffsets.count == 8)
            #expect(recordedOffsets.enumerated().allSatisfy { index, offset in
                offset == (index.isMultiple(of: 2) ? 1 : 3)
            })
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }
}

private actor OffsetLog {
    private(set) var values: [Int] = []

    func record(_ offset: Int) -> Int {
        values.append(offset)
        return values.count
    }
}

private actor ScanResponses {
    private var responses: [String]
    private(set) var offsets: [Int] = []

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next(offset: Int) -> String? {
        offsets.append(offset)
        return responses.isEmpty ? nil : responses.removeFirst()
    }
}
