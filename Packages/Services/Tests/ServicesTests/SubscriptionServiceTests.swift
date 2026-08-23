import Foundation
import StoreKit
import Testing
@testable import Services

// MARK: - Week Pass Math

@Suite("SubscriptionService — Week Pass expiry math")
struct WeekPassMathTests {
    private let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Week Pass expires 7 days after purchase")
    func expiryDate() {
        let expiry = SubscriptionService.weekPassExpiryDate(purchaseDate: purchaseDate)
        let expectedSeconds = TimeInterval(7 * 86400)
        #expect(expiry.timeIntervalSince(purchaseDate) == expectedSeconds)
    }

    @Test("Week Pass is active before 7 days")
    func activeBeforeExpiry() {
        let day6 = purchaseDate.addingTimeInterval(6 * 86400)
        #expect(SubscriptionService.isWeekPassActive(purchaseDate: purchaseDate, at: day6))
    }

    @Test("Week Pass is inactive after 7 days")
    func inactiveAfterExpiry() {
        let day8 = purchaseDate.addingTimeInterval(8 * 86400)
        #expect(!SubscriptionService.isWeekPassActive(purchaseDate: purchaseDate, at: day8))
    }

    @Test("Week Pass is inactive exactly at expiry boundary")
    func inactiveAtBoundary() {
        let exactExpiry = purchaseDate.addingTimeInterval(7 * 86400)
        #expect(!SubscriptionService.isWeekPassActive(purchaseDate: purchaseDate, at: exactExpiry))
    }
}

// MARK: - Cooldown Math

@Suite("SubscriptionService — Week Pass cooldown math")
struct CooldownMathTests {
    private let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var weekPassExpiry: Date {
        SubscriptionService.weekPassExpiryDate(purchaseDate: purchaseDate)
    }

    @Test("Cooldown ends 14 days after Week Pass expiry")
    func cooldownEndDate() {
        let cooldownEnd = SubscriptionService.weekPassCooldownEndDate(weekPassExpiry: weekPassExpiry)
        let expectedDays = TimeInterval(14 * 86400)
        #expect(cooldownEnd.timeIntervalSince(weekPassExpiry) == expectedDays)
    }

    @Test("Cooldown is not over during cooldown period")
    func cooldownActive() {
        let duringCooldown = weekPassExpiry.addingTimeInterval(10 * 86400)
        #expect(!SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: duringCooldown))
    }

    @Test("Cooldown is over after 14 days")
    func cooldownExpired() {
        let afterCooldown = weekPassExpiry.addingTimeInterval(15 * 86400)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: afterCooldown))
    }

    @Test("Cooldown is over exactly at boundary")
    func cooldownBoundary() {
        let exactEnd = weekPassExpiry.addingTimeInterval(14 * 86400)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: exactEnd))
    }

    @Test("Total lockout from purchase is 21 days (7 + 14)")
    func totalLockout() {
        let totalDays = TimeInterval(21 * 86400)
        let unlockDate = purchaseDate.addingTimeInterval(totalDays)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: unlockDate))

        let dayBefore = purchaseDate.addingTimeInterval(20 * 86400)
        #expect(!SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: dayBefore))
    }
}

// MARK: - Pro Renewal State

@Suite("SubscriptionService — Pro renewal state")
struct ProRenewalStateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("StoreKit grace expiration controls Pro access")
    func usesStoreGrace() {
        let transactionExpiry = now.addingTimeInterval(-86400)
        let graceExpiry = now.addingTimeInterval(3 * 86400)
        let snapshot = StoreEntitlementSnapshot(
            proStatuses: [
                StoreProStatus(
                    productID: SubscriptionProductID.proMonthly,
                    state: .gracePeriod,
                    transactionExpiry: transactionExpiry,
                    graceExpiry: graceExpiry
                ),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.proAccess == .billingGrace(expiresAt: graceExpiry))
        #expect(state.nextBoundary == graceExpiry)
    }

    @Test("Billing retry without grace does not grant Pro")
    func rejectsBillingRetry() {
        let snapshot = StoreEntitlementSnapshot(
            proStatuses: [
                StoreProStatus(
                    productID: SubscriptionProductID.proYearly,
                    state: .billingRetry,
                    transactionExpiry: now.addingTimeInterval(-1),
                    graceExpiry: nil
                ),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .free)
        #expect(state.proAccess == nil)
        #expect(state.nextBoundary == nil)
    }

    @Test("Cancelled renewal keeps access but reports expiry")
    func reportsCancelledRenewal() {
        let expiry = now.addingTimeInterval(86400)
        let snapshot = StoreEntitlementSnapshot(
            proStatuses: [
                StoreProStatus(
                    productID: SubscriptionProductID.proMonthly,
                    state: .subscribed,
                    transactionExpiry: expiry,
                    graceExpiry: nil,
                    willRenew: false
                ),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.proAccess == .active(expiresAt: expiry, willRenew: false))
    }
}

// MARK: - Entitlement Resolution

@Suite("SubscriptionService — entitlement resolution")
struct EntitlementResolutionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Newest active Week Pass defines access and boundary")
    func usesNewestWeekPass() {
        let olderPurchase = now.addingTimeInterval(-6 * 86400)
        let newerPurchase = now.addingTimeInterval(-2 * 86400)
        let expectedExpiry = newerPurchase.addingTimeInterval(7 * 86400)
        let snapshot = StoreEntitlementSnapshot(
            weekPassPurchases: [newerPurchase, olderPurchase]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .weekPass)
        #expect(state.weekPassExpiry == expectedExpiry)
        #expect(state.nextBoundary == expectedExpiry)
    }

    @Test("Week Pass is Free exactly at its expiry boundary")
    func expiresWeekPass() {
        let purchase = now.addingTimeInterval(-7 * 86400)
        let snapshot = StoreEntitlementSnapshot(weekPassPurchases: [purchase])

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .free)
        #expect(state.weekPassExpiry == now)
        #expect(state.nextBoundary == nil)
    }

    @Test("Active Pro takes priority over Week Pass")
    func proTakesPriority() {
        let weekPassExpiry = now.addingTimeInterval(5 * 86400)
        let proExpiry = now.addingTimeInterval(30 * 86400)
        let snapshot = StoreEntitlementSnapshot(
            weekPassPurchases: [now.addingTimeInterval(-2 * 86400)],
            proStatuses: [
                StoreProStatus(
                    productID: SubscriptionProductID.proMonthly,
                    state: .subscribed,
                    transactionExpiry: proExpiry,
                    graceExpiry: nil,
                    willRenew: true
                ),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.weekPassExpiry == weekPassExpiry)
        #expect(state.proAccess == .active(expiresAt: proExpiry, willRenew: true))
        #expect(state.nextBoundary == proExpiry)
    }
}

// MARK: - Entitlement Lifecycle

@Suite("SubscriptionService — entitlement lifecycle")
@MainActor
struct EntitlementLifecycleTests {
    @Test("Week Pass downgrades at expiry without a transaction update")
    func downgradesWeekPass() async throws {
        let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = purchaseDate.addingTimeInterval(7 * 86400)
        let date = TestDate(purchaseDate.addingTimeInterval(6 * 86400))
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(weekPassPurchases: [purchaseDate])
        )
        let sleeper = TestSleeper()
        var tierChangeCount = 0
        let service = try SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: #require(UserDefaults(suiteName: UUID().uuidString)),
            dateProvider: date.now,
            entitlementSource: source,
            sleep: sleeper.sleep,
            tierChangeHandler: { tierChangeCount += 1 }
        )

        await service.refreshEntitlements()

        #expect(service.currentTier == .weekPass)
        #expect(await sleeper.waitForDelay() == .seconds(86400))
        #expect(tierChangeCount == 1)

        date.set(expiry)
        await sleeper.resume()
        await source.waitForSnapshots(2)

        #expect(service.currentTier == .free)
        #expect(tierChangeCount == 2)
    }

    @Test("Store update refreshes a running service")
    func refreshesOnStoreUpdate() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(
                proStatuses: [
                    StoreProStatus(
                        productID: SubscriptionProductID.proMonthly,
                        state: .subscribed,
                        transactionExpiry: now.addingTimeInterval(86400),
                        graceExpiry: nil
                    ),
                ]
            )
        )
        var tierChangeCount = 0
        let service = try SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: #require(UserDefaults(suiteName: UUID().uuidString)),
            dateProvider: { now },
            entitlementSource: source,
            productLoader: { [] },
            tierChangeHandler: { tierChangeCount += 1 }
        )

        await service.start()
        #expect(service.currentTier == .pro)

        await source.setSnapshot(StoreEntitlementSnapshot())
        await source.emitUpdate()
        await source.waitForSnapshots(2)

        #expect(service.currentTier == .free)
        #expect(tierChangeCount == 2)
    }

    @Test("Refresh cancels the old boundary before rearming")
    func rearmsBoundary() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let laterPurchase = now.addingTimeInterval(86400)
        let source = EntitlementStub(
            snapshot: StoreEntitlementSnapshot(weekPassPurchases: [now])
        )
        let sleeper = TestSleeper()
        let service = try SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: #require(UserDefaults(suiteName: UUID().uuidString)),
            dateProvider: { now },
            entitlementSource: source,
            sleep: sleeper.sleep
        )

        await service.refreshEntitlements()
        #expect(await sleeper.waitForDelay() == .seconds(7 * 86400))

        await source.setSnapshot(
            StoreEntitlementSnapshot(weekPassPurchases: [now, laterPurchase])
        )
        await service.refreshEntitlements()
        await sleeper.waitForCancellation()
        await sleeper.waitForDelay(.seconds(8 * 86400))

        #expect(await sleeper.pendingDelays() == [.seconds(8 * 86400)])
    }

    @Test("Older refresh cannot restore stale access")
    func rejectsStaleRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = SequencedSource()
        let service = try SubscriptionService(
            counterStore: CounterStub(),
            userDefaults: #require(UserDefaults(suiteName: UUID().uuidString)),
            dateProvider: { now },
            entitlementSource: source
        )
        let firstRefresh = Task { @MainActor in
            await service.refreshEntitlements()
        }
        await source.waitForRequests(1)
        let secondRefresh = Task { @MainActor in
            await service.refreshEntitlements()
        }
        await source.waitForRequests(2)

        await source.respond(to: 1, with: StoreEntitlementSnapshot())
        await secondRefresh.value
        await source.respond(
            to: 0,
            with: StoreEntitlementSnapshot(weekPassPurchases: [now])
        )
        await firstRefresh.value

        #expect(service.currentTier == .free)
    }
}

private actor SequencedSource: StoreEntitlementSource {
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<StoreEntitlementSnapshot, Never>] = [:]

    func snapshot(products: [StoreKit.Product]) async -> StoreEntitlementSnapshot {
        _ = products
        let request = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    nonisolated func updates() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    func waitForRequests(_ expectedCount: Int) async {
        while requestCount < expectedCount {
            await Task.yield()
        }
    }

    func respond(to request: Int, with snapshot: StoreEntitlementSnapshot) {
        continuations.removeValue(forKey: request)?.resume(returning: snapshot)
    }
}

private actor EntitlementStub: StoreEntitlementSource {
    private var value: StoreEntitlementSnapshot
    private var snapshotCount = 0
    nonisolated private let updateFeed = UpdateFeed()

    init(snapshot: StoreEntitlementSnapshot) {
        value = snapshot
    }

    func snapshot(products: [StoreKit.Product]) async -> StoreEntitlementSnapshot {
        _ = products
        snapshotCount += 1
        return value
    }

    nonisolated func updates() -> AsyncStream<Void> {
        updateFeed.stream
    }

    func setSnapshot(_ snapshot: StoreEntitlementSnapshot) {
        value = snapshot
    }

    func emitUpdate() {
        updateFeed.emit()
    }

    func waitForSnapshots(_ expectedCount: Int) async {
        while snapshotCount < expectedCount {
            await Task.yield()
        }
    }
}

private final class UpdateFeed: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func emit() {
        continuation.yield()
    }
}

private actor TestSleeper {
    private struct Wait {
        let delay: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waits: [UUID: Wait] = [:]
    private var cancellationCount = 0

    func sleep(for delay: Duration) async throws {
        let waitID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waits[waitID] = Wait(delay: delay, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waitID) }
        }
    }

    func waitForDelay() async -> Duration? {
        while waits.isEmpty {
            await Task.yield()
        }
        return waits.values.first?.delay
    }

    func resume() {
        guard let waitID = waits.keys.first, let wait = waits.removeValue(forKey: waitID) else { return }
        wait.continuation.resume()
    }

    func waitForCancellation() async {
        while cancellationCount == 0 {
            await Task.yield()
        }
    }

    func pendingDelays() -> [Duration] {
        waits.values.map(\.delay).sorted()
    }

    func waitForDelay(_ expectedDelay: Duration) async {
        while !waits.values.contains(where: { $0.delay == expectedDelay }) {
            await Task.yield()
        }
    }

    private func cancel(_ waitID: UUID) {
        guard let wait = waits.removeValue(forKey: waitID) else { return }
        cancellationCount += 1
        wait.continuation.resume(throwing: CancellationError())
    }
}

private final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ value: Date) {
        lock.withLock { self.value = value }
    }
}

private final class CounterStub: SubscriptionCounterStore {
    func counter(forKey key: String) -> Int64 {
        _ = key
        return 0
    }

    func setCounter(_ value: Int64, forKey key: String) {
        _ = value
        _ = key
    }
}

// MARK: - Duration Constants

@Suite("SubscriptionService — duration constants")
struct DurationConstantTests {
    @Test("Week Pass duration is 7 days")
    func weekPassDays() {
        #expect(SubscriptionDuration.weekPassDays == 7)
    }

    @Test("Cooldown is 14 days")
    func cooldownDays() {
        #expect(SubscriptionDuration.weekPassCooldownDays == 14)
    }
}
