import Core
import Foundation
@testable import Services

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

    static func manualPreview(
        configuration: FixPlanConfig,
        requestedTestArtists: [String],
        knownTrackCount: Int?
    ) -> Self {
        preview(
            trigger: .manualCheck,
            configuration: configuration,
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount
        )
    }
}

actor FixPlanProducerProbe {
    private(set) var callCount = 0
    private let production: FixPlanProduction

    init(production: FixPlanProduction) {
        self.production = production
    }

    func produce(runID _: RunID, scope _: ProcessingScopeSnapshot) throws -> FixPlanProduction {
        callCount += 1
        return production
    }
}

actor ScopeProbe {
    private(set) var scope: ProcessingScopeSnapshot?

    func record(_ scope: ProcessingScopeSnapshot) {
        self.scope = scope
    }
}

func automaticInput(
    planID: FixPlanID,
    planning: RunConfig,
    capturedAt: Date
) -> FixPlanWriteInput {
    let scope = ProcessingScopeSnapshot(
        id: planning.scopeID,
        createdAt: capturedAt,
        source: .fullLibrary,
        normalizedTestArtists: [],
        matchingRule: "test",
        knownTrackCount: 75,
        fingerprint: "fullLibrary::tracks=75",
        reason: "automatic-write-test"
    )
    return FixPlanWriteInput(
        target: FixPlanWriteTarget(
            planID: planID,
            planRevision: .initial,
            decisionRevision: .initial
        ),
        scope: scope,
        admission: processingAdmission(scope: scope),
        configuration: RunConfig(
            capturedAt: capturedAt,
            mode: planning.mode,
            writeAuthority: .automaticPlan,
            automation: planning.automation,
            scopeID: scope.id,
            settings: planning.settings,
            hadRecoveryHold: false
        ),
        workItems: [makeWorkItem(state: .prepared)]
    )
}

actor RunRecordProbe {
    private(set) var records: [RunRecord] = []
    private var persistError: Error?
    private var finishedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ record: RunRecord) throws {
        if let persistError {
            throw persistError
        }
        records.append(record)
        resumeFinishedWaiters()
    }

    func setPersistError(_ error: Error) {
        persistError = error
    }

    func waitUntilFinished(count: Int) async {
        if finishedCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            finishedWaiters.append((count, continuation))
        }
    }

    private var finishedCount: Int {
        records.count { $0.finishedAt != nil }
    }

    private func resumeFinishedWaiters() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in finishedWaiters {
            if finishedCount >= count {
                continuation.resume()
            } else {
                waiting.append((count, continuation))
            }
        }
        finishedWaiters = waiting
    }
}

actor ProcessingSuccessProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

actor GatedRunRecordProbe {
    private var callCount = 0
    private let gatedCall: Int
    private let gate: SyncGate

    init(gatedCall: Int, gate: SyncGate) {
        self.gatedCall = gatedCall
        self.gate = gate
    }

    func append(_ record: RunRecord) async throws {
        _ = record
        callCount += 1
        if callCount == gatedCall {
            await gate.waitUntilReleased()
        }
    }
}

actor SyncGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if hasEntered {
            return
        }

        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilReleased() async {
        hasEntered = true
        resumeEnteredContinuations()

        if isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }

    private func resumeEnteredContinuations() {
        for continuation in enteredContinuations {
            continuation.resume()
        }
        enteredContinuations = []
    }
}
