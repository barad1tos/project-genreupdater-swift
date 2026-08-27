import Foundation
import Testing
@testable import Core

@Suite("Analytics models")
struct AnalyticsModelsTests {
    @Test("Operations keep stable persisted identities and categories")
    func operationIdentity() {
        #expect(AnalyticsOperation.libraryLoad.rawValue == "library.load")
        #expect(AnalyticsOperation.discogsReleaseSearch.category == .provider)
        #expect(AnalyticsOperation.batchWrite.category == .write)
        #expect(AnalyticsOperation.displayName(for: "future.operation") == "Unknown operation")
    }

    @Test("Errors distinguish cancellation from failure")
    func errorOutcome() {
        #expect(AnalyticsOutcome(error: CancellationError(), isTaskCancelled: false) == .cancelled)
        #expect(AnalyticsOutcome(error: URLError(.cancelled), isTaskCancelled: false) == .cancelled)
        #expect(AnalyticsOutcome(error: SampleError.failed, isTaskCancelled: false) == .failed)
        #expect(AnalyticsOutcome(error: SampleError.failed, isTaskCancelled: true) == .cancelled)
    }

    @Test("Stored analytics outcomes retain old values and degraded state")
    func outcomeCoding() throws {
        let outcomes: [AnalyticsOutcome] = [.succeeded, .failed, .cancelled, .degraded]

        for outcome in outcomes {
            let encoded = try JSONEncoder().encode(outcome)
            #expect(try JSONDecoder().decode(AnalyticsOutcome.self, from: encoded) == outcome)
        }

        #expect(try JSONDecoder().decode(AnalyticsOutcome.self, from: Data("\"succeeded\"".utf8)) == .succeeded)
        #expect(try JSONDecoder().decode(AnalyticsOutcome.self, from: Data("\"failed\"".utf8)) == .failed)
        #expect(try JSONDecoder().decode(AnalyticsOutcome.self, from: Data("\"cancelled\"".utf8)) == .cancelled)
    }

    @Test("Measurement returns the original value and records once")
    func measurementValue() async throws {
        let recorder = AnalyticsRecorderDouble()

        let value = await recorder.measure(.libraryLoad) { 42 }
        let events = await recorder.events
        let event = try #require(events.first)

        #expect(value == 42)
        #expect(events.count == 1)
        #expect(event.operation == .libraryLoad)
        #expect(event.outcome == .succeeded)
        #expect(event.duration >= .zero)
    }

    @Test("Measurement rethrows the original error and records once")
    func measurementError() async {
        let recorder = AnalyticsRecorderDouble()

        do {
            _ = try await recorder.measure(.yearDetermination) {
                throw SampleError.failed
            }
            Issue.record("Expected the measured operation to throw")
        } catch {
            #expect(error as? SampleError == .failed)
        }

        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events.first?.operation == .yearDetermination)
        #expect(events.first?.outcome == .failed)
    }
}

private actor AnalyticsRecorderDouble: AnalyticsService {
    struct Event: Sendable {
        let operation: AnalyticsOperation
        let duration: Duration
        let outcome: AnalyticsOutcome
    }

    private(set) var events: [Event] = []

    func record(_ operation: AnalyticsOperation, duration: Duration, outcome: AnalyticsOutcome) {
        events.append(Event(operation: operation, duration: duration, outcome: outcome))
    }
}

private enum SampleError: Error {
    case failed
}
