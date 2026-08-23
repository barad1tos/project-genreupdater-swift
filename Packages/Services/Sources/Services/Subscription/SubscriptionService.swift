// SubscriptionService.swift — StoreKit 2 subscription management.
//
// Manages 3-tier model: Free / Week Pass / Pro.
// - Week Pass: non-renewing, 7-day expiry, 14-day cooldown
// - Pro: auto-renewable (monthly/yearly), including StoreKit billing grace
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

    static var weekPassInterval: TimeInterval {
        TimeInterval(weekPassDays * 86400)
    }
    static var weekPassCooldownInterval: TimeInterval {
        TimeInterval(weekPassCooldownDays * 86400)
    }
}

// MARK: - iCloud KVS Keys

private enum KVSKey {
    static let freeTracksUsed = "freeTracksUsed"
    static let weekPassPurchaseCount = "weekPassPurchaseCount"
}

protocol SubscriptionCounterStore: AnyObject {
    func counter(forKey key: String) -> Int64
    func setCounter(_ value: Int64, forKey key: String)
}

extension NSUbiquitousKeyValueStore: SubscriptionCounterStore {
    func counter(forKey key: String) -> Int64 {
        longLong(forKey: key)
    }

    func setCounter(_ value: Int64, forKey key: String) {
        set(NSNumber(value: value), forKey: key)
    }
}

// MARK: - SubscriptionService

@MainActor
@Observable
public final class SubscriptionService {
    // MARK: - Published State

    public private(set) var currentTier: Tier = .free
    public private(set) var weekPassExpiry: Date?
    public private(set) var proAccess: ProAccessState?
    public private(set) var freeTracksUsed: Int = 0
    public private(set) var weekPassPurchaseCount: Int = 0
    public private(set) var isLoading = true

    // MARK: - Products

    public private(set) var products: [Product] = []

    // MARK: - Internal State

    @ObservationIgnored private var entitlementListener: Task<Void, Never>?
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshVersion = 0
    private let counterStore: any SubscriptionCounterStore
    private let userDefaults: UserDefaults
    private let dateProvider: @Sendable () -> Date
    private let entitlementSource: any StoreEntitlementSource
    private let productLoader: @Sendable () async throws -> [Product]
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let tierChangeHandler: @MainActor () -> Void

    private static let localCounterKey = "freeTracksUsed_local"

    // MARK: - Init

    /// Creates the StoreKit-backed subscription service.
    ///
    /// - Parameters:
    ///   - iCloudStore: Persistent source for subscription usage counters.
    ///   - userDefaults: Local fallback for the free-track counter.
    ///   - dateProvider: Current-time source used for entitlement expiry decisions.
    ///   - tierChangeHandler: Called when a refreshed entitlement changes the active tier.
    public convenience init(
        iCloudStore: NSUbiquitousKeyValueStore = .default,
        userDefaults: UserDefaults = .standard,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        tierChangeHandler: @escaping @MainActor () -> Void = {
            // Standalone consumers have no app runtime to reconfigure.
        }
    ) {
        self.init(
            counterStore: iCloudStore,
            userDefaults: userDefaults,
            dateProvider: dateProvider,
            entitlementSource: StoreKitSource(),
            productLoader: {
                try await Product.products(for: SubscriptionProductID.allProductIDs)
            },
            sleep: { try await Task.sleep(for: $0) },
            tierChangeHandler: tierChangeHandler
        )
    }

    init(
        counterStore: any SubscriptionCounterStore,
        userDefaults: UserDefaults,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        entitlementSource: any StoreEntitlementSource = StoreKitSource(),
        productLoader: @escaping @Sendable () async throws -> [Product] = {
            try await Product.products(for: SubscriptionProductID.allProductIDs)
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        tierChangeHandler: @escaping @MainActor () -> Void = {
            // Custom counter-store consumers opt in to tier-change effects.
        }
    ) {
        self.counterStore = counterStore
        self.userDefaults = userDefaults
        self.dateProvider = dateProvider
        self.entitlementSource = entitlementSource
        self.productLoader = productLoader
        self.sleep = sleep
        self.tierChangeHandler = tierChangeHandler
    }

    deinit {
        entitlementListener?.cancel()
        boundaryTask?.cancel()
    }

    // MARK: - Lifecycle

    public func start() async {
        isLoading = true
        loadICloudCounters()
        await loadProducts()
        await refreshEntitlements()
        listenForUpdates()
        isLoading = false
        log.info("SubscriptionService started, tier=\(String(describing: self.currentTier), privacy: .public)")
    }

    // MARK: - Purchase

    public func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()

        switch result {
        case let .success(verification):
            let transaction = try checkVerification(verification)
            await refreshEntitlements()
            await transaction.finish()
            recordWeekPassPurchase(transaction)
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
        counterStore.setCounter(Int64(freeTracksUsed), forKey: KVSKey.freeTracksUsed)
        userDefaults.set(freeTracksUsed, forKey: Self.localCounterKey)

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
            products = try await productLoader()
                .sorted { $0.price < $1.price }
            log.info("Loaded \(self.products.count, privacy: .public) products")
        } catch {
            log.error("Failed to load products: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Internal: Entitlements

    func refreshEntitlements() async {
        refreshVersion += 1
        let version = refreshVersion
        let now = dateProvider()
        let snapshot = await entitlementSource.snapshot(products: products)
        guard version == refreshVersion else { return }
        let state = Self.resolveEntitlements(snapshot, at: now)
        applyEntitlementState(
            tier: state.tier,
            weekPassExpiry: state.weekPassExpiry,
            proAccess: state.proAccess
        )
        scheduleBoundary(at: state.nextBoundary)
    }

    func applyEntitlementState(
        tier: Tier,
        weekPassExpiry: Date?,
        proAccess: ProAccessState?
    ) {
        let previousTier = currentTier
        currentTier = tier
        self.weekPassExpiry = weekPassExpiry
        self.proAccess = proAccess
        if tier != previousTier {
            tierChangeHandler()
        }
    }

    // MARK: - Internal: Lifecycle

    private func listenForUpdates() {
        entitlementListener?.cancel()
        entitlementListener = Task(priority: .utility) { @MainActor [weak self] in
            guard let updates = self?.entitlementSource.updates() else { return }
            for await _ in updates {
                guard let self else { return }
                await self.refreshEntitlements()
            }
        }
    }

    private func scheduleBoundary(at deadline: Date?) {
        boundaryTask?.cancel()
        let now = dateProvider()
        guard let deadline, deadline > now else {
            boundaryTask = nil
            return
        }

        let delay = Duration.seconds(deadline.timeIntervalSince(now))
        let sleep = sleep
        boundaryTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                await self?.refreshEntitlements()
            } catch is CancellationError {
                return
            } catch {
                log.error("Entitlement boundary wait failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Internal: Verification

    nonisolated private func checkVerification(
        _ verification: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch verification {
        case let .verified(transaction):
            return transaction
        case let .unverified(_, error):
            log.error("Transaction verification failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Internal: iCloud Counters

    private func loadICloudCounters() {
        let iCloudValue = Int(counterStore.counter(forKey: KVSKey.freeTracksUsed))
        let localValue = userDefaults.integer(forKey: Self.localCounterKey)
        freeTracksUsed = max(iCloudValue, localValue)
        userDefaults.set(freeTracksUsed, forKey: Self.localCounterKey)

        weekPassPurchaseCount = Int(counterStore.counter(forKey: KVSKey.weekPassPurchaseCount))
        log.debug(
            "Counters loaded: tracks=\(self.freeTracksUsed, privacy: .public) (iCloud=\(iCloudValue, privacy: .public), local=\(localValue, privacy: .public)), weekPasses=\(self.weekPassPurchaseCount, privacy: .public)"
        )
    }

    private func recordWeekPassPurchase(_ transaction: Transaction) {
        guard transaction.productID == SubscriptionProductID.weekPass else { return }
        weekPassPurchaseCount += 1
        counterStore.setCounter(Int64(weekPassPurchaseCount), forKey: KVSKey.weekPassPurchaseCount)
    }
}

// MARK: - Testable Math (pure functions)

extension SubscriptionService {
    nonisolated static func resolveEntitlements(
        _ snapshot: StoreEntitlementSnapshot,
        at now: Date
    ) -> ResolvedEntitlements {
        let weekPassExpiry = snapshot.weekPassPurchases
            .map(weekPassExpiryDate(purchaseDate:))
            .max()
        let proAccess = snapshot.proStatuses.compactMap { status -> ProAccessState? in
            guard SubscriptionProductID.proProductIDs.contains(status.productID) else { return nil }

            switch status.state {
            case .subscribed:
                guard let expiry = status.transactionExpiry, expiry > now else { return nil }
                return .active(expiresAt: expiry, willRenew: status.willRenew ?? false)
            case .gracePeriod:
                guard let expiry = status.graceExpiry, expiry > now else { return nil }
                return .billingGrace(expiresAt: expiry)
            case .billingRetry, .expired, .revoked:
                return nil
            }
        }.max { lhs, rhs in
            lhs.expiry < rhs.expiry
        }

        if let proAccess {
            return ResolvedEntitlements(
                tier: .pro,
                weekPassExpiry: weekPassExpiry,
                proAccess: proAccess,
                nextBoundary: proAccess.expiry
            )
        }

        if let weekPassExpiry, weekPassExpiry > now {
            return ResolvedEntitlements(
                tier: .weekPass,
                weekPassExpiry: weekPassExpiry,
                proAccess: nil,
                nextBoundary: weekPassExpiry
            )
        }

        return ResolvedEntitlements(
            tier: .free,
            weekPassExpiry: weekPassExpiry,
            proAccess: nil,
            nextBoundary: nil
        )
    }

    /// Calculate Week Pass expiry from purchase date. Pure function for testing.
    nonisolated public static func weekPassExpiryDate(purchaseDate: Date) -> Date {
        purchaseDate.addingTimeInterval(SubscriptionDuration.weekPassInterval)
    }

    /// Calculate cooldown end date from Week Pass expiry. Pure function for testing.
    nonisolated public static func weekPassCooldownEndDate(weekPassExpiry: Date) -> Date {
        weekPassExpiry.addingTimeInterval(SubscriptionDuration.weekPassCooldownInterval)
    }

    /// Whether a Week Pass is active at the given date. Pure function for testing.
    nonisolated public static func isWeekPassActive(purchaseDate: Date, at now: Date) -> Bool {
        now < weekPassExpiryDate(purchaseDate: purchaseDate)
    }

    /// Whether cooldown has passed since Week Pass expiry. Pure function for testing.
    nonisolated public static func isCooldownOver(weekPassExpiry: Date, at now: Date) -> Bool {
        now >= weekPassCooldownEndDate(weekPassExpiry: weekPassExpiry)
    }
}
