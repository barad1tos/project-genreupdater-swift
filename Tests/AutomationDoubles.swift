import Core
import Foundation
import Services
@testable import Genre_Updater

extension RunRequest {
    static func manualObservation(
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        observation(
            trigger: .manualCheck,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }
}

/// The saver closure runs synchronously on MainActor with the command.
@MainActor
final class SavedStrategiesBox {
    var values: [AutomationStrategy] = []
}

/// Records registration calls; a set failure throws instead.
@MainActor
final class StubAgentRegistrar: AgentRegistrar {
    var isRegistered = false
    var needsApproval = false
    var failure: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        if let failure {
            throw failure
        }
        registerCalls += 1
        isRegistered = true
    }

    func unregister() async throws {
        if let failure {
            throw failure
        }
        unregisterCalls += 1
        isRegistered = false
    }

    func openApprovalSettings() {
        // Settings deep links are outside pin scope.
    }
}

enum AgentRegistrationFailure: Error {
    case denied
}

/// A hand-driven source: tests emit events and control availability.
/// The stream is created eagerly so an emit before the consumer
/// subscribes is buffered, not lost.
final class StubLibraryChangeSource: LibraryChangeSource, @unchecked Sendable {
    let isAvailable: Bool
    private(set) var isTerminated = false
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
        (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.onTermination = { [self] _ in
            isTerminated = true
        }
    }

    func events() -> AsyncStream<Void> {
        stream
    }

    func emit() {
        continuation.yield()
    }
}

actor AutomationRecordCollector {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) {
        records.append(record)
    }
}

actor AutomationSyncGate {
    private var isArmed = false
    private var isReleased = false
    private var isEntered = false
    private var enterContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func sync() async -> SyncResult {
        guard isArmed, !isReleased else { return SyncResult() }
        isEntered = true
        for continuation in enterContinuations {
            continuation.resume()
        }
        enterContinuations = []
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return SyncResult()
    }

    func waitUntilEntered() async {
        if isEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enterContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }
}
