import Core
import Foundation

extension RunOrchestrator {
    func finishRunWork(
        from lifecycle: RunLifecycleSnapshot,
        request: RunRequest
    ) async throws -> RunSubmissionResult {
        let work = try await performRunWork(from: lifecycle, request: request)
        let chainedRequest = try await automaticWriteRequest(
            for: work,
            planning: lifecycle,
            request: request
        )
        await releasePreview(request)
        if let failureMessage = work.failureMessage {
            return await finishFailedRun(
                from: work.reportingSource,
                failureMessage: failureMessage,
                syncResult: work.result,
                writeSummary: work.writeSummary
            )
        }
        return await finishSuccessfulRun(
            work,
            intent: request.intent,
            chainedRequest: chainedRequest
        )
    }

    private func automaticWriteRequest(
        for work: RunWork,
        planning: RunLifecycleSnapshot,
        request: RunRequest
    ) async throws -> RunRequest? {
        guard let configuration = planning.configuration,
              configuration.mode == .autoFix,
              configuration.hadRecoveryHold == false,
              recoveryState.hasWriteBlock == false,
              let planID = work.producedPlanID
        else { return nil }
        guard let prepareAutomaticWrite = dependencies.prepareAutomaticWrite else {
            throw RunWorkError.missingAutomaticWriteBuilder
        }
        let input = try await prepareAutomaticWrite(planID, configuration, request.trigger)
        guard recoveryState.hasWriteBlock == false else { return nil }
        guard input.target.planID == planID,
              input.scope.id == configuration.scopeID,
              input.configuration.mode == .autoFix,
              input.configuration.writeAuthority == .automaticPlan,
              input.configuration.automation == configuration.automation,
              input.configuration.scopeID == configuration.scopeID,
              input.configuration.settings == configuration.settings,
              input.configuration.hadRecoveryHold == false
        else {
            throw RunWorkError.invalidAutomaticWriteInput
        }
        return .automaticWrite(trigger: request.trigger, input: input)
    }

    func releasePreview(_ request: RunRequest) async {
        guard let configuration = request.previewConfiguration,
              let releasePreview = dependencies.releasePreview else { return }
        await releasePreview(configuration)
    }
}
