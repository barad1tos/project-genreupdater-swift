import Core
import Foundation
import OSLog
import StoreKit

private let entitlementLog = Logger(subsystem: "com.genreupdater", category: "StoreEntitlements")

/// Verified Pro access details used to present the current StoreKit renewal state.
public enum ProAccessState: Sendable, Equatable {
    /// Pro remains active until the transaction expires.
    case active(expiresAt: Date, willRenew: Bool)
    /// StoreKit billing grace keeps Pro active until the signed grace deadline.
    case billingGrace(expiresAt: Date)

    var expiry: Date {
        switch self {
        case let .active(expiresAt, _):
            expiresAt
        case let .billingGrace(expiresAt):
            expiresAt
        }
    }
}

enum StoreProRenewalState: Sendable, Equatable {
    case subscribed
    case gracePeriod
    case billingRetry
    case expired
    case revoked
}

struct StoreProStatus: Sendable, Equatable {
    let productID: String
    let state: StoreProRenewalState
    let transactionExpiry: Date?
    let graceExpiry: Date?
    let willRenew: Bool?

    init(
        productID: String,
        state: StoreProRenewalState,
        transactionExpiry: Date?,
        graceExpiry: Date?,
        willRenew: Bool? = nil
    ) {
        self.productID = productID
        self.state = state
        self.transactionExpiry = transactionExpiry
        self.graceExpiry = graceExpiry
        self.willRenew = willRenew
    }
}

struct StoreEntitlementSnapshot: Sendable, Equatable {
    var weekPassPurchases: [Date]
    var proStatuses: [StoreProStatus]

    init(
        weekPassPurchases: [Date] = [],
        proStatuses: [StoreProStatus] = []
    ) {
        self.weekPassPurchases = weekPassPurchases
        self.proStatuses = proStatuses
    }
}

struct ResolvedEntitlements: Sendable, Equatable {
    let tier: Tier
    let weekPassExpiry: Date?
    let proAccess: ProAccessState?
    let nextBoundary: Date?
}

protocol StoreEntitlementSource: Sendable {
    func snapshot(products: [Product]) async -> StoreEntitlementSnapshot
    func updates() -> AsyncStream<Void>
}

struct StoreKitSource: StoreEntitlementSource {
    func snapshot(products: [Product]) async -> StoreEntitlementSnapshot {
        async let currentEntitlements = loadCurrentEntitlements()
        async let proStatuses = loadProStatuses(products: products)
        let current = await currentEntitlements
        let statuses = await proStatuses
        let statusProductIDs = Set(statuses.map(\.productID))
        let fallbackStatuses = current.proStatuses.filter {
            !statusProductIDs.contains($0.productID)
        }
        return StoreEntitlementSnapshot(
            weekPassPurchases: current.weekPassPurchases,
            proStatuses: statuses + fallbackStatuses
        )
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let transactionTask = Task {
                for await result in Transaction.updates {
                    guard let transaction = verified(result) else { continue }
                    await transaction.finish()
                    continuation.yield()
                }
            }
            let statusTask = Task {
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard verified(status.transaction) != nil,
                          verified(status.renewalInfo) != nil
                    else { continue }
                    continuation.yield()
                }
            }

            continuation.onTermination = { _ in
                transactionTask.cancel()
                statusTask.cancel()
            }
        }
    }

    private func loadCurrentEntitlements() async -> StoreEntitlementSnapshot {
        var snapshot = StoreEntitlementSnapshot()
        for await result in Transaction.currentEntitlements {
            guard let transaction = verified(result) else { continue }
            if transaction.productID == SubscriptionProductID.weekPass {
                snapshot.weekPassPurchases.append(transaction.purchaseDate)
            } else if SubscriptionProductID.proProductIDs.contains(transaction.productID) {
                snapshot.proStatuses.append(
                    StoreProStatus(
                        productID: transaction.productID,
                        state: .subscribed,
                        transactionExpiry: transaction.expirationDate,
                        graceExpiry: nil,
                        willRenew: nil
                    )
                )
            }
        }
        return snapshot
    }

    private func loadProStatuses(products: [Product]) async -> [StoreProStatus] {
        let groupIDs = Set(products.compactMap { product -> String? in
            guard SubscriptionProductID.proProductIDs.contains(product.id) else { return nil }
            return product.subscription?.subscriptionGroupID
        })
        var result: [StoreProStatus] = []

        for groupID in groupIDs {
            do {
                let statuses = try await Product.SubscriptionInfo.status(for: groupID)
                result.append(contentsOf: statuses.compactMap(storeStatus))
            } catch {
                let statusError = error.localizedDescription
                entitlementLog.error(
                    "Subscription status failed: \(groupID, privacy: .public), \(statusError, privacy: .public)"
                )
            }
        }
        return result
    }

    private func storeStatus(_ status: Product.SubscriptionInfo.Status) -> StoreProStatus? {
        guard let transaction = verified(status.transaction),
              let renewalInfo = verified(status.renewalInfo),
              SubscriptionProductID.proProductIDs.contains(transaction.productID),
              let state = StoreProRenewalState(status.state)
        else { return nil }

        return StoreProStatus(
            productID: transaction.productID,
            state: state,
            transactionExpiry: transaction.expirationDate,
            graceExpiry: renewalInfo.gracePeriodExpirationDate,
            willRenew: renewalInfo.willAutoRenew
        )
    }

    private func verified<Value>(_ result: VerificationResult<Value>) -> Value? {
        guard case let .verified(value) = result else { return nil }
        return value
    }
}

extension StoreProRenewalState {
    fileprivate init?(_ state: Product.SubscriptionInfo.RenewalState) {
        switch state {
        case .subscribed:
            self = .subscribed
        case .inGracePeriod:
            self = .gracePeriod
        case .inBillingRetryPeriod:
            self = .billingRetry
        case .expired:
            self = .expired
        case .revoked:
            self = .revoked
        default:
            return nil
        }
    }
}
