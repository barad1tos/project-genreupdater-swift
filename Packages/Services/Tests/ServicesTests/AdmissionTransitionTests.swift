import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Write admission transitions")
struct AdmissionTransitionTests {
    @MainActor
    @Test("Batch admission uses one tier snapshot across all checks")
    func batchKeepsAdmissionTier() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tiers = TierSequence([.weekPass, .free])
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(
                tierProvider: { tiers.next() },
                freeTracksUsedProvider: { 0 },
                usageRecorder: { _ in
                    // This test exercises admission, not usage metering.
                }
            )
        )
        let track = Track(id: "T1", name: "The Mob Goes Wild", artist: "Clutch", album: "Blast Tyrant")

        let entries = try await processor.process(
            tracks: [track],
            validateWrite: passWriteValidation,
            operation: { _ in [] },
            progressHandler: { _ in
                // Progress is irrelevant to the admission assertion.
            }
        )

        #expect(entries.isEmpty)
    }

    @MainActor
    @Test("A free write remains metered after the user upgrades before completion")
    func freeWriteKeepsMetering() async throws {
        let counts = try await successfulWriteCounts(admissionTier: .free, completionTier: .pro)
        #expect(counts == [1])
    }

    @MainActor
    @Test("A paid write does not consume free allowance after a downgrade before completion")
    func paidWriteStaysUnmetered() async throws {
        let counts = try await successfulWriteCounts(admissionTier: .pro, completionTier: .free)
        #expect(counts.isEmpty)
    }

    @MainActor
    @Test("Partial writes keep metering from the admitted tier")
    func partialWriteKeepsAdmissionTier() async {
        let freeToPaid = await partialWriteCounts(admissionTier: .free, failureTier: .pro)
        let paidToFree = await partialWriteCounts(admissionTier: .pro, failureTier: .free)

        #expect(freeToPaid == [2])
        #expect(paidToFree.isEmpty)
    }

    @MainActor
    private func successfulWriteCounts(admissionTier: Tier, completionTier: Tier) async throws -> [Int] {
        let fixture = makeProcessor(tier: admissionTier)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = BatchUpdateResult(
            entries: [ChangeLogEntry(changeType: .genreUpdate, trackID: "T1", artist: "Artist")],
            failedTrackIDs: [],
            errorDescriptions: []
        )

        _ = try await fixture.processor.performRecoverableWrite(
            trackCount: 1,
            features: WriteFeatureRequirements(mutation: nil),
            validateWrite: passWriteValidation,
            outcome: WriteOutcomeProjection(
                appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                partialTrackIDs: { _ in [] }
            ),
            operation: {
                await fixture.tier.set(completionTier)
                return result
            }
        )
        return fixture.recordedCounts()
    }

    @MainActor
    private func partialWriteCounts(admissionTier: Tier, failureTier: Tier) async -> [Int] {
        let fixture = makeProcessor(tier: admissionTier)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let partialOutcome = TransitionPartialError(trackIDs: ["T1", "T2"])

        await #expect(throws: TransitionPartialError.self) {
            _ = try await fixture.processor.performRecoverableWrite(
                trackCount: 2,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { (_: MusicWriteResult) in [] },
                    partialTrackIDs: { error in
                        (error as? TransitionPartialError)?.trackIDs ?? []
                    }
                ),
                operation: {
                    await fixture.tier.set(failureTier)
                    throw partialOutcome
                }
            )
        }
        return fixture.recordedCounts()
    }

    @MainActor
    private func makeProcessor(tier: Tier) -> TransitionFixture {
        let directory = makeDirectory()
        let state = TierState(tier)
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(
                tierProvider: { state.value },
                freeTracksUsedProvider: { 0 },
                usageRecorder: { recordedCounts.append($0) }
            )
        )
        return TransitionFixture(
            directory: directory,
            tier: state,
            processor: processor,
            recordedCounts: { recordedCounts }
        )
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BP-\(UUID().uuidString)")
    }
}

@MainActor
private struct TransitionFixture {
    let directory: URL
    let tier: TierState
    let processor: BatchProcessor
    let recordedCounts: () -> [Int]
}

@MainActor
private final class TierState {
    var value: Tier

    init(_ value: Tier) {
        self.value = value
    }

    func set(_ value: Tier) {
        self.value = value
    }
}

@MainActor
private final class TierSequence {
    private var values: [Tier]

    init(_ values: [Tier]) {
        self.values = values
    }

    func next() -> Tier {
        let value = values.first ?? .free
        if values.count > 1 {
            values.removeFirst()
        }
        return value
    }
}

private struct TransitionPartialError: Error {
    let trackIDs: Set<String>
}
