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
                return "BATCH:2:3:10,20"
            case 3:
                return "BATCH:3:3:30"
            default:
                return nil
            }
        }

        #expect(try await scan.run() == ["10", "20", "30"])
    }

    @Test("Rejects a track count change between batches")
    func rejectsCountChange() async {
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { offset, _, _ in
            offset == 1 ? "BATCH:2:3:10,20" : "BATCH:4:4:30,40"
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
            offset == 1 ? "BATCH:2:3:10,20" : "BATCH:3:3:20"
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
            "BATCH:0:0:"
        }

        #expect(try await scan.run().isEmpty)
    }

    @Test("Rejects a batch returned after the scan deadline")
    func rejectsLateBatch() async {
        let scan = TrackIDScan(batchSize: 10, timeout: .milliseconds(5)) { _, _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return "BATCH:1:1:10"
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
}
