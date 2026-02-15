import Foundation
import Testing
@testable import Services

// MARK: - Week Pass Math

@Suite("SubscriptionService — Week Pass expiry math")
struct WeekPassMathTests {
    private let purchaseDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Week Pass expires 7 days after purchase")
    func expiryDate() {
        let expiry = SubscriptionService.weekPassExpiryDate(purchaseDate: purchaseDate)
        let expectedSeconds = TimeInterval(7 * 86_400)
        #expect(expiry.timeIntervalSince(purchaseDate) == expectedSeconds)
    }

    @Test("Week Pass is active before 7 days")
    func activeBeforeExpiry() {
        let day6 = purchaseDate.addingTimeInterval(6 * 86_400)
        #expect(SubscriptionService.isWeekPassActive(purchaseDate: purchaseDate, at: day6))
    }

    @Test("Week Pass is inactive after 7 days")
    func inactiveAfterExpiry() {
        let day8 = purchaseDate.addingTimeInterval(8 * 86_400)
        #expect(!SubscriptionService.isWeekPassActive(purchaseDate: purchaseDate, at: day8))
    }

    @Test("Week Pass is inactive exactly at expiry boundary")
    func inactiveAtBoundary() {
        let exactExpiry = purchaseDate.addingTimeInterval(7 * 86_400)
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
        let expectedDays = TimeInterval(14 * 86_400)
        #expect(cooldownEnd.timeIntervalSince(weekPassExpiry) == expectedDays)
    }

    @Test("Cooldown is not over during cooldown period")
    func cooldownActive() {
        let duringCooldown = weekPassExpiry.addingTimeInterval(10 * 86_400)
        #expect(!SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: duringCooldown))
    }

    @Test("Cooldown is over after 14 days")
    func cooldownExpired() {
        let afterCooldown = weekPassExpiry.addingTimeInterval(15 * 86_400)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: afterCooldown))
    }

    @Test("Cooldown is over exactly at boundary")
    func cooldownBoundary() {
        let exactEnd = weekPassExpiry.addingTimeInterval(14 * 86_400)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: exactEnd))
    }

    @Test("Total lockout from purchase is 21 days (7 + 14)")
    func totalLockout() {
        let totalDays = TimeInterval(21 * 86_400)
        let unlockDate = purchaseDate.addingTimeInterval(totalDays)
        #expect(SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: unlockDate))

        let dayBefore = purchaseDate.addingTimeInterval(20 * 86_400)
        #expect(!SubscriptionService.isCooldownOver(weekPassExpiry: weekPassExpiry, at: dayBefore))
    }
}

// MARK: - Pro Grace Period Math

@Suite("SubscriptionService — Pro grace period math")
struct ProGracePeriodTests {
    private let proExpiry = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Not in grace period while subscription is active")
    func activeSubscription() {
        let before = proExpiry.addingTimeInterval(-86_400)
        #expect(!SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: before))
    }

    @Test("In grace period right after expiry")
    func graceStart() {
        let justAfter = proExpiry.addingTimeInterval(1)
        #expect(SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: justAfter))
    }

    @Test("In grace period at exactly expiry")
    func graceAtExpiry() {
        #expect(SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: proExpiry))
    }

    @Test("In grace period at day 15")
    func graceDay15() {
        let day15 = proExpiry.addingTimeInterval(15 * 86_400)
        #expect(SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: day15))
    }

    @Test("Not in grace period after 16 days")
    func graceExpired() {
        let day17 = proExpiry.addingTimeInterval(17 * 86_400)
        #expect(!SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: day17))
    }

    @Test("Grace period is exactly 16 days")
    func graceBoundary() {
        let exactEnd = proExpiry.addingTimeInterval(16 * 86_400)
        #expect(!SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: exactEnd))

        let justBefore = proExpiry.addingTimeInterval(16 * 86_400 - 1)
        #expect(SubscriptionService.isProInGracePeriod(expiryDate: proExpiry, at: justBefore))
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

    @Test("Pro grace period is 16 days")
    func graceDays() {
        #expect(SubscriptionDuration.proGracePeriodDays == 16)
    }

    @Test("Offline cache is 7 days")
    func offlineDays() {
        #expect(SubscriptionDuration.offlineCacheDays == 7)
    }
}
