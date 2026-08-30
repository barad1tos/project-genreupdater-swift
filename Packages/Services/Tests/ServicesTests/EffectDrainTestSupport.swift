@testable import Services

extension MirrorEffectDrain {
    func waitForQueuedRequest() async {
        while !hasQueuedDrainRequest {
            await Task.yield()
        }
    }
}

actor BlockingProjectionRecorder: MirrorProjectionOutput {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func refreshMirrorProjections() async throws {
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

actor SingleFlightProjectionRecorder: MirrorProjectionOutput {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshCount = 0

    func refreshMirrorProjections() async throws {
        refreshCount += 1
        guard refreshCount == 1 else { return }
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

actor RetryProjectionRecorder: MirrorProjectionOutput {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private(set) var refreshCount = 0

    func refreshMirrorProjections() async throws {
        refreshCount += 1
        guard refreshCount == 1 else { return }
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
        throw EffectTargetFailure.requested
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
