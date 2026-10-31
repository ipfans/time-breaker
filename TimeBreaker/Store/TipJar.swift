import Observation
import StoreKit
import os

/// Optional tips that support development.
///
/// Tips are consumable in-app purchases that unlock nothing. Products load only when Support is
/// shown. Every transaction is finished as soon as it arrives, including ones that complete while
/// Settings is closed, such as an approved Ask to Buy request.
@MainActor
@Observable
final class TipJar {
    /// Product identifiers, which must match App Store Connect and `TimeBreaker.storekit`.
    enum Tier: String, CaseIterable, Sendable {
        case small = "com.acgso.timebreaker.tip.small"
        case medium = "com.acgso.timebreaker.tip.medium"
        case large = "com.acgso.timebreaker.tip.large"
    }

    enum Availability: Equatable, Sendable {
        case notLoaded
        case loading
        case available
        /// Nothing loaded, for example while offline or before App Store Connect offers the tips.
        case unavailable
    }

    enum PurchaseStatus: Equatable, Sendable {
        case idle
        case purchasing(Tier)
        /// Awaiting approval, such as Ask to Buy; the transaction arrives through `Transaction.updates`.
        case pending
        case thanked
        case failed
    }

    /// Presents the App Store purchase sheet. On macOS the sheet needs a window to attach to, so
    /// Settings supplies one; `Product.purchase()` without a window fails.
    typealias Purchase = @MainActor (Product) async throws -> Product.PurchaseResult

    private(set) var availability: Availability = .notLoaded
    private(set) var products: [Tier: Product] = [:]
    private(set) var status: PurchaseStatus = .idle

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: Log.subsystem, category: "TipJar")

    var isPurchasing: Bool {
        if case .purchasing = status { true } else { false }
    }

    /// Finishes transactions delivered outside a purchase in progress, including ones left
    /// unfinished when the app last quit. Call once at launch.
    func startObservingTransactions() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if await finish(result) {
                    status = .thanked
                }
            }
        }
    }

    func stopObservingTransactions() {
        updates?.cancel()
        updates = nil
    }

    /// Loads tips the first time Support is shown, and again after a failure.
    func loadProducts() async {
        guard availability == .notLoaded || availability == .unavailable else { return }
        availability = .loading
        do {
            let loaded = try await Product.products(for: Tier.allCases.map(\.rawValue))
            products = Dictionary(uniqueKeysWithValues: loaded.compactMap { product in
                Tier(rawValue: product.id).map { ($0, product) }
            })
        } catch {
            products = [:]
            logger.error("Loading tips failed: \(error.localizedDescription, privacy: .public)")
        }
        availability = products.isEmpty ? .unavailable : .available
    }

    func purchase(_ tier: Tier, using purchase: Purchase) async {
        guard let product = products[tier], !isPurchasing else { return }
        status = .purchasing(tier)
        do {
            switch try await purchase(product) {
            case .success(let result):
                status = await finish(result) ? .thanked : .failed
            case .pending:
                status = .pending
            case .userCancelled:
                status = .idle
            @unknown default:
                status = .idle
            }
        } catch {
            logger.error("Tip purchase failed: \(error.localizedDescription, privacy: .public)")
            status = .failed
        }
    }

    /// Finishes a transaction and reports whether it was a verified tip.
    ///
    /// Tips deliver no content, so unverified transactions are finished too; otherwise StoreKit
    /// would deliver them again at every launch.
    private func finish(_ result: VerificationResult<Transaction>) async -> Bool {
        let transaction = result.unsafePayloadValue
        await transaction.finish()
        switch result {
        case .verified:
            logger.notice("Finished tip \(transaction.productID, privacy: .public)")
            return Tier(rawValue: transaction.productID) != nil
        case .unverified(_, let error):
            logger.error("Finished unverified transaction: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
