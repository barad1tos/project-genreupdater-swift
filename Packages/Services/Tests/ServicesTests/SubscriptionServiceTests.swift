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
        let graceExpiry = now.addingTimeInterval(3 * 86400)
        let snapshot = StoreEntitlementSnapshot(
            proStatuses: [
                .billingGrace(expiresAt: graceExpiry),
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
                .notEntitled,
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
                .active(expiresAt: expiry, renewal: .expires),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.proAccess == .active(expiresAt: expiry, renewal: .expires))
    }

    @Test("Unavailable subscription status preserves verified Pro access")
    func preservesUnavailableStatus() {
        let snapshot = StoreEntitlementSnapshot(proStatuses: [.statusUnavailable])

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.proAccess == .statusUnavailable)
        #expect(state.nextBoundary == now.addingTimeInterval(SubscriptionDuration.statusRetryInterval))
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
                .active(expiresAt: proExpiry, renewal: .renews),
            ]
        )

        let state = SubscriptionService.resolveEntitlements(snapshot, at: now)

        #expect(state.tier == .pro)
        #expect(state.weekPassExpiry == weekPassExpiry)
        #expect(state.proAccess == .active(expiresAt: proExpiry, renewal: .renews))
        #expect(state.nextBoundary == proExpiry)
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

    @Test("StoreKit status retry is centrally configured")
    func statusRetry() {
        #expect(SubscriptionDuration.statusRetrySeconds == 300)
    }
}
