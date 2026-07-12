import Core
import Foundation
import Testing
@testable import Services

@Suite("Track lookup")
struct TrackLookupTests {
    @Test("Batches IDs under one deadline")
    func batchesIDs() async throws {
        let calls = LookupCalls()
        let clock = LookupClock()
        let batchTimeout = Duration.milliseconds(300)
        let lookup = TrackLookup(batchSize: 2, timeout: batchTimeout, now: clock.now) { ids, remaining in
            await calls.record(ids: ids, remaining: remaining)
            return ids.joined(separator: ",")
        } parse: { output in
            if output == "A,B" {
                clock.advance(by: .milliseconds(400))
            }
            return output.split(separator: ",").map {
                Track(id: String($0), name: "Track", artist: "Artist", album: "Album")
            }
        }

        #expect(try await lookup.run(ids: ["A", "B", "C"]).map(\.id) == ["A", "B", "C"])
        let recorded = await calls.values
        #expect(recorded.map(\.ids) == [["A", "B"], ["C"]])
        #expect(recorded[0].remaining <= batchTimeout)
        #expect(recorded[1].remaining < batchTimeout)
    }

    @Test("Clamps non-positive batch sizes")
    func clampsBatchSize() async throws {
        let calls = LookupCalls()
        let lookup = TrackLookup(batchSize: 0, timeout: .seconds(1)) { ids, remaining in
            await calls.record(ids: ids, remaining: remaining)
            return nil
        } parse: { _ in [] }

        #expect(try await lookup.run(ids: ["A", "B"]).isEmpty)
        #expect(await calls.values.map(\.ids) == [["A"], ["B"]])
    }

    @Test("Clamps oversized batches")
    func clampsOversizedBatch() async throws {
        let calls = LookupCalls()
        let ids = (1 ... 1001).map(String.init)
        let lookup = TrackLookup(batchSize: 5000, timeout: .seconds(1)) { ids, remaining in
            await calls.record(ids: ids, remaining: remaining)
            return nil
        } parse: { _ in [] }

        #expect(try await lookup.run(ids: ids).isEmpty)
        #expect(await calls.values.map(\.ids.count) == [1000, 1])
    }

    @Test("Skips unresolved batches")
    func skipsUnresolvedBatches() async throws {
        let responses = LookupResponses([nil, "", "C"])
        let lookup = TrackLookup(batchSize: 1, timeout: .seconds(1)) { _, _ in
            await responses.next()
        } parse: { output in
            output.isEmpty ? [] : [Track(id: output, name: "Track", artist: "Artist", album: "Album")]
        }

        #expect(try await lookup.run(ids: ["A", "B", "C"]).map(\.id) == ["C"])
    }

    @Test("Rejects a final batch returned after the deadline")
    func rejectsLateBatch() async {
        let lookup = TrackLookup(batchSize: 2, timeout: .milliseconds(5)) { _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return "A"
        } parse: { _ in [] }

        do {
            _ = try await lookup.run(ids: ["A"])
            Issue.record("Expected the lookup deadline to expire")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Stops before dispatch after the total deadline")
    func stopsBeforeNextBatch() async {
        let calls = LookupCalls()
        let clock = LookupClock(offsets: [.zero, .zero, .zero, .milliseconds(700)])
        let lookup = TrackLookup(batchSize: 1, timeout: .milliseconds(300), now: clock.now) { ids, remaining in
            await calls.record(ids: ids, remaining: remaining)
            return nil
        } parse: { _ in [] }

        do {
            _ = try await lookup.run(ids: ["A", "B"])
            Issue.record("Expected the lookup deadline to expire before the next batch")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
            #expect(await calls.values.map(\.ids) == [["A"]])
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Rejects a late unresolved final batch")
    func rejectsLateNil() async {
        let lookup = TrackLookup(batchSize: 2, timeout: .milliseconds(5)) { _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return nil
        } parse: { _ in [] }

        do {
            _ = try await lookup.run(ids: ["A"])
            Issue.record("Expected the unresolved lookup deadline to expire")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Rejects a final batch parsed after the deadline")
    func rejectsLateParse() async {
        let calls = LookupCalls()
        let lookup = TrackLookup(batchSize: 1, timeout: .milliseconds(5)) { ids, remaining in
            await calls.record(ids: ids, remaining: remaining)
            return ids[0]
        } parse: { output in
            Thread.sleep(forTimeInterval: 0.03)
            return [Track(id: output, name: "Track", artist: "Artist", album: "Album")]
        }

        do {
            _ = try await lookup.run(ids: ["A"])
            Issue.record("Expected the lookup deadline to expire")
        } catch let error as AppleScriptBridgeError {
            guard case .timeout = error else {
                Issue.record("Expected timeout, got \(error)")
                return
            }
            #expect(await calls.values.map(\.ids) == [["A"]])
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Propagates parse failures")
    func propagatesParseFailure() async {
        let lookup = TrackLookup(batchSize: 1, timeout: .seconds(1)) { _, _ in
            "invalid"
        } parse: { _ in
            throw LookupTestError.invalidOutput
        }

        await #expect(throws: LookupTestError.invalidOutput) {
            _ = try await lookup.run(ids: ["A"])
        }
    }
}

private enum LookupTestError: Error {
    case invalidOutput
}

private final class LookupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    private var offsets: [Duration]

    init(offsets: [Duration] = []) {
        self.offsets = offsets
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            let offset = offsets.isEmpty ? .zero : offsets.removeFirst()
            return instant.advanced(by: offset)
        }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            instant = instant.advanced(by: duration)
        }
    }
}

private actor LookupCalls {
    struct Call: Sendable {
        let ids: [String]
        let remaining: Duration
    }

    private(set) var values: [Call] = []

    func record(ids: [String], remaining: Duration) {
        values.append(Call(ids: ids, remaining: remaining))
    }
}

private actor LookupResponses {
    private var values: [String?]

    init(_ values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        values.removeFirst()
    }
}
