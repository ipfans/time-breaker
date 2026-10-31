import StoreKit
import StoreKitTest
import Testing
@testable import TimeBreaker

/// Tip loading and purchase-result handling against the local StoreKit configuration. Purchases
/// themselves aren't made here; test them by running the app from Xcode. StoreKit test state is
/// process-wide, so the suite runs serially.
@MainActor
@Suite("Tip jar", .serialized)
struct TipJarTests {
    let session: SKTestSession

    init() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "TimeBreaker", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
    }

    @Test func everyTierLoadsAsAConsumableInPriceOrder() async throws {
        let jar = TipJar()
        await jar.loadProducts()
        #expect(jar.availability == .available)
        let products = try TipJar.Tier.allCases.map { try #require(jar.products[$0]) }
        #expect(products.allSatisfy { $0.type == .consumable })
        #expect(products.map(\.price) == products.map(\.price).sorted())
        #expect(Set(products.map(\.price)).count == products.count)
    }

    @Test func cancelledTipReturnsToIdle() async {
        let jar = TipJar()
        await jar.loadProducts()
        await jar.purchase(.small) { _ in .userCancelled }
        #expect(jar.status == .idle)
    }

    @Test func pendingTipIsReported() async {
        let jar = TipJar()
        await jar.loadProducts()
        await jar.purchase(.large) { _ in .pending }
        #expect(jar.status == .pending)
    }

    @Test func purchaseErrorIsReported() async {
        let jar = TipJar()
        await jar.loadProducts()
        await jar.purchase(.small) { _ in throw StoreKitError.networkError(URLError(.notConnectedToInternet)) }
        #expect(jar.status == .failed)
    }

    @Test func unavailableTipsCanBeRetried() async throws {
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let jar = TipJar()
        await jar.loadProducts()
        #expect(jar.availability == .unavailable)
        #expect(jar.products.isEmpty)

        await jar.purchase(.small) { _ in
            Issue.record("Purchased a tip that never loaded")
            return .userCancelled
        }
        #expect(jar.status == .idle)

        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await jar.loadProducts()
        #expect(jar.availability == .available)
    }

    @Test func loadedTipsAreNotRequestedAgain() async throws {
        let jar = TipJar()
        await jar.loadProducts()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await jar.loadProducts()
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        #expect(jar.availability == .available)
        #expect(jar.products.count == TipJar.Tier.allCases.count)
    }
}

private final class BundleToken {}
