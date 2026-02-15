// SubscriptionService.swift — StoreKit 2 subscription management.
//
// Manages 3-tier model: Free / Week Pass / Pro.
// - Week Pass: non-renewing, 7-day expiry, 14-day cooldown
// - Pro: auto-renewable (monthly/yearly), 16-day billing grace period
// - Free counter: NSUbiquitousKeyValueStore (iCloud KVS)

import Core
import Foundation
import OSLog
import StoreKit

private let log = Logger(subsystem: "com.genreupdater", category: "SubscriptionService")

// MARK: - Product IDs

public enum SubscriptionProductID {
    public static let weekPass = "genreupdater.weekpass"
    public static let proMonthly = "genreupdater.pro.monthly"
    public static let proYearly = "genreupdater.pro.yearly"

    static let allProductIDs: Set<String> = [weekPass, proMonthly, proYearly]
    static let proProductIDs: Set<String> = [proMonthly, proYearly]
}

// MARK: - Time Constants

public enum SubscriptionDuration {
    public static let weekPassDays = 7
    public static let weekPassCooldownDays = 14
    public static let proGracePeriodDays = 16
    public static let offlineCacheDays = 7

    static var weekPassInterval: TimeInterval { TimeInterval(weekPassDays * 86_400) }
    static var weekPassCooldownInterval: TimeInterval { TimeInterval(weekPassCooldownDays * 86_400) }
    static var proGraceInterval: TimeInterval { TimeInterval(proGracePeriodDays * 86_400) }
}

// MARK: - iCloud KVS Keys

private enum KVSKey {
    static let freeTracksUsed = "freeTracksUsed"
    static let weekPassPurchaseCount = "weekPassPurchaseCount"
}

// MARK: - SubscriptionService

@MainActor
@Observable
public final class SubscriptionService {

    // MARK: - Published State

    public private(set) var currentTier: Tier = .free
    public private(set) var weekPassExpiry: Date?
    public private(set) var proExpiry: Date?
    public private(set) var freeTracksUsed: Int = 0
    public private(set) var weekPassPurchaseCount: Int = 0
    public private(set) var isLoading = true

    // MARK: - Products

    public private(set) var products: [Product] = []

    // MARK: - Internal State

    @ObservationIgnored private var transactionListener: Task<Void, Never>?
    private let iCloudStore: NSUbiquitousKeyValueStore
    private let dateProvider: @Sendable () -> Date

    // MARK: - Init

    public init(
        iCloudStore: NSUbiquitousKeyValueStore = .default,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.iCloudStore = iCloudStore
        self.dateProvider = dateProvider
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Lifecycle

    public func start() async {
        isLoading = true
        loadICloudCounters()
        await loadProducts()
        await refreshEntitlements()
        listenForTransactions()
        isLoading = false
        log.info("SubscriptionService started, tier=\(String(describing: self.currentTier), privacy: .public)")
    }

    // MARK: - Purchase

    public func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerification(verification)
            await refreshEntitlements()
            await transaction.finish()
            trackWeekPassPurchaseIfNeeded(transaction)
            log.info("Purchase succeeded: \(product.id, privacy: .public)")
            return transaction

        case .userCancelled:
            log.info("Purchase cancelled by user")
            return nil

        case .pending:
            log.info("Purchase pending approval")
            return nil

        @unknown default:
            log.warning("Unknown purchase result")
            return nil
        }
    }

    public func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
        log.info("Purchases restored, tier=\(String(describing: self.currentTier), privacy: .public)")
    }

    // MARK: - Free Tier Counter

    public func incrementFreeTracksUsed(by count: Int) {
        freeTracksUsed += count
        iCloudStore.set(Int64(freeTracksUsed), forKey: KVSKey.freeTracksUsed)

        log.debug("Free tracks used: \(self.freeTracksUsed, privacy: .public)")
    }

    // MARK: - Week Pass Cooldown

    /// Time remaining before a new Week Pass can be purchased. Nil means purchasable now.
    public var weekPassCooldownRemaining: TimeInterval? {
        guard let expiry = weekPassExpiry else { return nil }
        let now = dateProvider()
        guard expiry < now else { return nil }
        let cooldownEnd = expiry.addingTimeInterval(SubscriptionDuration.weekPassCooldownInterval)
        let remaining = cooldownEnd.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    /// Whether a Week Pass can be purchased right now.
    public var canPurchaseWeekPass: Bool {
        weekPassCooldownRemaining == nil
    }

    // MARK: - Internal: Products

    private func loadProducts() async {
        do {
            products = try await Product.products(for: SubscriptionProductID.allProductIDs)
                .sorted { $0.price < $1.price }
            log.info("Loaded \(self.products.count, privacy: .public) products")
        } catch {
            log.error("Failed to load products: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internal: Entitlements

    func refreshEntitlements() async {
        var detectedTier: Tier = .free
        var detectedWeekPassExpiry: Date?
        var detectedProExpiry: Date?
        let now = dateProvider()

        for await verification in Transaction.currentEntitlements {
            guard let transaction = try? checkVerification(verification) else { continue }

            if SubscriptionProductID.proProductIDs.contains(transaction.productID) {
                let expiry = proExpiryDate(for: transaction)
                if let expiry, expiry > now {
                    detectedTier = .pro
                    detectedProExpiry = expiry
                } else if let expiry,
                    expiry.addingTimeInterval(SubscriptionDuration.proGraceInterval) > now
                {
                    detectedTier = max(detectedTier, .pro)
                    detectedProExpiry = expiry
                }
            }

            if transaction.productID == SubscriptionProductID.weekPass {
                let expiry = transaction.purchaseDate.addingTimeInterval(
                    SubscriptionDuration.weekPassInterval)
                detectedWeekPassExpiry = expiry
                if expiry > now && detectedTier < .weekPass {
                    detectedTier = .weekPass
                }
            }
        }

        currentTier = detectedTier
        weekPassExpiry = detectedWeekPassExpiry
        proExpiry = detectedProExpiry
    }

    // MARK: - Internal: Transaction Listener

    private func listenForTransactions() {
        transactionListener = Task(priority: .utility) { @MainActor [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerification(verification) {
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Internal: Verification

    private nonisolated func checkVerification(
        _ verification: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch verification {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            log.error("Transaction verification failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Internal: Pro Expiry

    private nonisolated func proExpiryDate(for transaction: Transaction) -> Date? {
        transaction.expirationDate
    }

    // MARK: - Internal: iCloud Counters

    private func loadICloudCounters() {

        freeTracksUsed = Int(iCloudStore.longLong(forKey: KVSKey.freeTracksUsed))
        weekPassPurchaseCount = Int(iCloudStore.longLong(forKey: KVSKey.weekPassPurchaseCount))
        log.debug(
            "iCloud counters loaded: tracks=\(self.freeTracksUsed, privacy: .public), weekPasses=\(self.weekPassPurchaseCount, privacy: .public)"
        )
    }

    private func trackWeekPassPurchaseIfNeeded(_ transaction: Transaction) {
        guard transaction.productID == SubscriptionProductID.weekPass else { return }
        weekPassPurchaseCount += 1
        iCloudStore.set(Int64(weekPassPurchaseCount), forKey: KVSKey.weekPassPurchaseCount)

    }
}

// MARK: - Testable Math (pure functions)

extension SubscriptionService {

    /// Calculate Week Pass expiry from purchase date. Pure function for testing.
    public nonisolated static func weekPassExpiryDate(purchaseDate: Date) -> Date {
        purchaseDate.addingTimeInterval(SubscriptionDuration.weekPassInterval)
    }

    /// Calculate cooldown end date from Week Pass expiry. Pure function for testing.
    public nonisolated static func weekPassCooldownEndDate(weekPassExpiry: Date) -> Date {
        weekPassExpiry.addingTimeInterval(SubscriptionDuration.weekPassCooldownInterval)
    }

    /// Whether a Week Pass is active at the given date. Pure function for testing.
    public nonisolated static func isWeekPassActive(purchaseDate: Date, at now: Date) -> Bool {
        now < weekPassExpiryDate(purchaseDate: purchaseDate)
    }

    /// Whether a Pro subscription is in grace period. Pure function for testing.
    public nonisolated static func isProInGracePeriod(expiryDate: Date, at now: Date) -> Bool {
        now >= expiryDate
            && now < expiryDate.addingTimeInterval(SubscriptionDuration.proGraceInterval)
    }

    /// Whether cooldown has passed since Week Pass expiry. Pure function for testing.
    public nonisolated static func isCooldownOver(weekPassExpiry: Date, at now: Date) -> Bool {
        now >= weekPassCooldownEndDate(weekPassExpiry: weekPassExpiry)
    }
}
