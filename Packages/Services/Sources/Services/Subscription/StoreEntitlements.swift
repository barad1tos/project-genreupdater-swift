import Core
import Foundation
import OSLog
import StoreKit

private let entitlementLog = Logger(subsystem: "com.genreupdater", category: "StoreEntitlements")

/// Whether StoreKit reports that an active Pro subscription will renew.
public enum ProRenewalIntent: Sendable, Equatable {
    case renews
    case expires
    /// Access is verified, but StoreKit does not provide a definitive renewal intent.
    case unknown
}

/// Verified Pro access details used to present the current StoreKit renewal state.
public enum ProAccessState: Sendable, Equatable {
    /// The current transaction boundary and StoreKit renewal intent.
    case active(expiresAt: Date, renewal: ProRenewalIntent)
    /// The signed deadline for the current StoreKit billing grace period.
    case billingGrace(expiresAt: Date)
    /// StoreKit verifies access but cannot currently provide renewal details.
    case statusUnavailable

    var expiry: Date? {
        switch self {
        case let .active(expiresAt, _), let .billingGrace(expiresAt):
            expiresAt
        case .statusUnavailable:
            nil
        }
    }
}

enum StoreProStatus: Sendable, Equatable {
    case active(expiresAt: Date, renewal: ProRenewalIntent)
    case billingGrace(expiresAt: Date)
    case statusUnavailable
    case notEntitled

    func access(at date: Date) -> ProAccessState? {
        switch self {
        case let .active(expiresAt, renewal):
            guard expiresAt > date else { return nil }
            return .active(expiresAt: expiresAt, renewal: renewal)
        case let .billingGrace(expiresAt):
            guard expiresAt > date else { return nil }
            return .billingGrace(expiresAt: expiresAt)
        case .statusUnavailable:
            return .statusUnavailable
        case .notEntitled:
            return nil
        }
    }
}

enum StoreEntitlement: Sendable, Equatable {
    case weekPass(transactionID: UInt64?, purchaseDate: Date)
    case pro(transactionID: UInt64?, status: StoreProStatus)

    var transactionID: UInt64? {
        switch self {
        case let .weekPass(transactionID, _), let .pro(transactionID, _):
            transactionID
        }
    }

    func isApplied(at date: Date) -> Bool {
        switch self {
        case let .weekPass(_, purchaseDate):
            SubscriptionService.weekPassExpiryDate(purchaseDate: purchaseDate) > date
        case let .pro(_, status):
            status.access(at: date) != nil
        }
    }
}

struct StoreEntitlementSnapshot: Sendable, Equatable {
    var entitlements: [StoreEntitlement]

    init(
        weekPassPurchases: [Date] = [],
        proStatuses: [StoreProStatus] = []
    ) {
        entitlements = weekPassPurchases.map {
            .weekPass(transactionID: nil, purchaseDate: $0)
        } + proStatuses.map {
            .pro(transactionID: nil, status: $0)
        }
    }

    init(entitlements: [StoreEntitlement]) {
        self.entitlements = entitlements
    }

    var weekPassPurchases: [Date] {
        entitlements.compactMap { entitlement in
            guard case let .weekPass(_, purchaseDate) = entitlement else { return nil }
            return purchaseDate
        }
    }

    var proStatuses: [StoreProStatus] {
        entitlements.compactMap { entitlement in
            guard case let .pro(_, status) = entitlement else { return nil }
            return status
        }
    }

    var currentTransactionIDs: Set<UInt64> {
        Set(entitlements.compactMap(\.transactionID))
    }

    func appliedTransactionIDs(at date: Date) -> Set<UInt64> {
        Set(entitlements.compactMap { entitlement in
            guard entitlement.isApplied(at: date) else { return nil }
            return entitlement.transactionID
        })
    }
}

enum StoreSnapshotRead: Sendable, Equatable {
    case complete(StoreEntitlementSnapshot)
    case verificationFailed(StoreEntitlementSnapshot)

    var snapshot: StoreEntitlementSnapshot {
        switch self {
        case let .complete(snapshot), let .verificationFailed(snapshot):
            snapshot
        }
    }

    var isVerified: Bool {
        if case .complete = self {
            return true
        }
        return false
    }
}

enum StoreDeliveryDecision: Sendable, Equatable {
    case grant
    case removal
    case pending
}

enum StoreDeliveryState: Sendable {
    case grantPending
    case removalPending
    case statusPending(resolve: @Sendable () async -> StoreDeliveryDecision)
}

struct StoreDeliveryFacts: Sendable {
    let productID: String
    let revocationDate: Date?
    let isUpgraded: Bool
    let expirationDate: Date?
    let subscriptionState: Product.SubscriptionInfo.RenewalState?
}

struct StoreTransactionDelivery: Sendable {
    let id: UInt64
    let productID: String
    var state: StoreDeliveryState
    let isPurchase: Bool
    let finish: @Sendable () async -> Void

    init(
        id: UInt64,
        productID: String,
        state: StoreDeliveryState = .grantPending,
        isPurchase: Bool = false,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.productID = productID
        self.state = state
        self.isPurchase = isPurchase
        self.finish = finish
    }
}

enum StoreUpdate: Sendable {
    case transaction(StoreTransactionDelivery)
    case status
}

struct ResolvedEntitlements: Sendable, Equatable {
    let tier: Tier
    let weekPassExpiry: Date?
    let proAccess: ProAccessState?
    let nextBoundary: Date?
}

protocol StoreEntitlementSource: Sendable {
    func snapshot() async -> StoreSnapshotRead
    func updates() -> AsyncStream<StoreUpdate>
}

struct StoreKitSource: StoreEntitlementSource {
    private let dateProvider: @Sendable () -> Date

    init(dateProvider: @escaping @Sendable () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    func snapshot() async -> StoreSnapshotRead {
        var snapshot = StoreEntitlementSnapshot()
        var didFailVerification = false

        for await result in Transaction.currentEntitlements {
            switch result {
            case let .verified(transaction):
                if transaction.productID == SubscriptionProductID.weekPass {
                    snapshot.entitlements.append(
                        .weekPass(transactionID: transaction.id, purchaseDate: transaction.purchaseDate)
                    )
                } else if SubscriptionProductID.proProductIDs.contains(transaction.productID) {
                    await snapshot.entitlements.append(
                        .pro(transactionID: transaction.id, status: proStatus(for: transaction))
                    )
                }
            case let .unverified(transaction, error):
                didFailVerification = true
                logVerificationFailure(
                    context: "current entitlement",
                    productID: transaction.productID,
                    error: error
                )
            }
        }

        return didFailVerification ? .verificationFailed(snapshot) : .complete(snapshot)
    }

    func updates() -> AsyncStream<StoreUpdate> {
        AsyncStream { continuation in
            let transactionTask = Task {
                for await result in Transaction.updates {
                    switch result {
                    case let .verified(transaction):
                        await continuation.yield(transactionUpdate(for: transaction))
                    case let .unverified(transaction, error):
                        logVerificationFailure(
                            context: "transaction update",
                            productID: transaction.productID,
                            error: error
                        )
                        continuation.yield(.status)
                    }
                }
            }
            let statusTask = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    logStatusFailures(status)
                    continuation.yield(.status)
                }
            }

            continuation.onTermination = { _ in
                transactionTask.cancel()
                statusTask.cancel()
            }
        }
    }

    private func transactionUpdate(for transaction: Transaction) async -> StoreUpdate {
        let state = await deliveryState(for: transaction)
        return .transaction(
            StoreTransactionDelivery(
                id: transaction.id,
                productID: transaction.productID,
                state: state,
                finish: { await transaction.finish() }
            )
        )
    }

    static func deliveryDecision(for facts: StoreDeliveryFacts, at date: Date) -> StoreDeliveryDecision {
        if facts.revocationDate != nil || facts.isUpgraded {
            return .removal
        }
        if SubscriptionProductID.proProductIDs.contains(facts.productID) {
            switch facts.subscriptionState {
            case .subscribed?, .inGracePeriod?:
                return .grant
            case .inBillingRetryPeriod?, .expired?, .revoked?:
                return .removal
            case nil, _?:
                return .pending
            }
        }
        if let expirationDate = facts.expirationDate, expirationDate <= date {
            return .removal
        }
        return .grant
    }

    private func deliveryState(for transaction: Transaction) async -> StoreDeliveryState {
        switch await deliveryDecision(for: transaction) {
        case .grant:
            .grantPending
        case .removal:
            .removalPending
        case .pending:
            .statusPending(resolve: { await deliveryDecision(for: transaction) })
        }
    }

    private func deliveryDecision(for transaction: Transaction) async -> StoreDeliveryDecision {
        if transaction.revocationDate != nil || transaction.isUpgraded {
            return .removal
        }
        guard SubscriptionProductID.proProductIDs.contains(transaction.productID) else {
            return Self.deliveryDecision(
                for: StoreDeliveryFacts(
                    productID: transaction.productID,
                    revocationDate: nil,
                    isUpgraded: false,
                    expirationDate: transaction.expirationDate,
                    subscriptionState: nil
                ),
                at: dateProvider()
            )
        }
        guard let status = await transaction.subscriptionStatus else {
            entitlementLog.warning(
                "Delivery status unavailable: \(transaction.productID, privacy: .public)"
            )
            return .pending
        }
        guard let statusTransaction = verifiedTransaction(status.transaction, context: "delivery status"),
              statusTransaction.productID == transaction.productID,
              verifiedRenewal(status.renewalInfo, productID: transaction.productID) != nil
        else { return .pending }

        return Self.deliveryDecision(
            for: StoreDeliveryFacts(
                productID: transaction.productID,
                revocationDate: transaction.revocationDate,
                isUpgraded: transaction.isUpgraded,
                expirationDate: transaction.expirationDate,
                subscriptionState: status.state
            ),
            at: dateProvider()
        )
    }

    private func proStatus(for transaction: Transaction) async -> StoreProStatus {
        guard let status = await transaction.subscriptionStatus else {
            entitlementLog.warning(
                "Subscription status unavailable: \(transaction.productID, privacy: .public)"
            )
            return .statusUnavailable
        }
        guard let statusTransaction = verifiedTransaction(status.transaction, context: "subscription status") else {
            return .statusUnavailable
        }
        guard statusTransaction.productID == transaction.productID else {
            entitlementLog.warning(
                "Subscription status product mismatch: current=\(transaction.productID, privacy: .public), status=\(statusTransaction.productID, privacy: .public)"
            )
            return .statusUnavailable
        }
        guard let renewal = verifiedRenewal(status.renewalInfo, productID: transaction.productID) else {
            return .statusUnavailable
        }

        switch status.state {
        case .subscribed:
            guard let expiry = statusTransaction.expirationDate else {
                entitlementLog.warning(
                    "Active subscription has no expiry: \(transaction.productID, privacy: .public)"
                )
                return .statusUnavailable
            }
            let intent: ProRenewalIntent = renewal.willAutoRenew ? .renews : .expires
            return .active(expiresAt: expiry, renewal: intent)
        case .inGracePeriod:
            guard let expiry = renewal.gracePeriodExpirationDate else {
                entitlementLog.warning(
                    "Grace subscription has no deadline: \(transaction.productID, privacy: .public)"
                )
                return .statusUnavailable
            }
            return .billingGrace(expiresAt: expiry)
        case .inBillingRetryPeriod, .expired, .revoked:
            return .notEntitled
        default:
            entitlementLog.warning(
                "Unknown subscription state: \(transaction.productID, privacy: .public)"
            )
            return .statusUnavailable
        }
    }

    private func verifiedTransaction(
        _ result: VerificationResult<Transaction>,
        context: StaticString
    ) -> Transaction? {
        switch result {
        case let .verified(transaction):
            return transaction
        case let .unverified(transaction, error):
            logVerificationFailure(context: context, productID: transaction.productID, error: error)
            return nil
        }
    }

    private func verifiedRenewal(
        _ result: VerificationResult<Product.SubscriptionInfo.RenewalInfo>,
        productID: String
    ) -> Product.SubscriptionInfo.RenewalInfo? {
        switch result {
        case let .verified(renewal):
            return renewal
        case let .unverified(_, error):
            logVerificationFailure(context: "renewal info", productID: productID, error: error)
            return nil
        }
    }

    private func logStatusFailures(_ status: Product.SubscriptionInfo.Status) {
        let productID: String
        switch status.transaction {
        case let .verified(transaction):
            productID = transaction.productID
        case let .unverified(transaction, error):
            productID = transaction.productID
            logVerificationFailure(context: "status update", productID: productID, error: error)
        }

        if case let .unverified(_, error) = status.renewalInfo {
            logVerificationFailure(context: "renewal update", productID: productID, error: error)
        }
    }

    private func logVerificationFailure(
        context: StaticString,
        productID: String,
        error: Error
    ) {
        let description = error.localizedDescription
        entitlementLog.error(
            "Unverified \(context, privacy: .public): \(productID, privacy: .public), \(description, privacy: .public)"
        )
    }
}
