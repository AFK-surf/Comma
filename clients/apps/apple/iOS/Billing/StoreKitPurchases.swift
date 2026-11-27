import Foundation
import StoreKit
import UIKit

/**
 * The App Store as the client core's `store.*` operations (`packages/core/src/hosts/mobile.ts`), with StoreKit 2.
 *
 * Only transactions StoreKit verified reach the core. The core reports each one to the server, which reads it from the
 * App Store again before it records it, and only then asks this to finish it: a transaction not finished stays in
 * `Transaction.unfinished` and is reported again.
 */
final class StoreKitPurchases: Sendable {
    /// One `store.*` operation's answer.
    func perform(_ command: String, _ input: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "products":
            let ids = (input["ids"] as? [String] ?? []).prefix(64)
            let products = try await Product.products(for: Array(ids))
            return ["products": products.map { ["id": $0.id, "displayPrice": $0.displayPrice] }]
        case "purchase":
            guard let id = input["productId"] as? String,
                  let token = (input["accountToken"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw HostFailure(message: "The purchase names no product or account.")
            }
            return try await purchase(id, token: token)
        case "unfinished":
            var transactions: [[String: Any]] = []
            for await result in Transaction.unfinished {
                guard case .verified(let transaction) = result else { continue }
                transactions.append(Self.json(transaction))
            }
            return ["transactions": transactions]
        case "finish":
            guard let id = (input["transaction"] as? String).flatMap(UInt64.init) else {
                throw HostFailure(message: "The transaction to finish is missing.")
            }
            for await result in Transaction.unfinished {
                guard case .verified(let transaction) = result, transaction.id == id else { continue }
                await transaction.finish()
            }
            return [:]
        case "sync":
            try await AppStore.sync()
            return [:]
        case "manage":
            try await Self.manage()
            return [:]
        default:
            throw HostFailure(message: "unknown operation: store.\(command)")
        }
    }

    private func purchase(_ id: String, token: UUID) async throws -> [String: Any] {
        guard let product = try await Product.products(for: [id]).first else {
            throw HostFailure(message: "The App Store does not sell this product.")
        }
        switch try await product.purchase(options: [.appAccountToken(token)]) {
        case .success(.verified(let transaction)):
            return ["status": "purchased", "transaction": Self.json(transaction)]
        case .success(.unverified):
            throw HostFailure(message: "The App Store could not verify the purchase.")
        case .pending: return ["status": "pending"]
        case .userCancelled: return ["status": "cancelled"]
        @unknown default: return ["status": "pending"]
        }
    }

    private static func json(_ transaction: Transaction) -> [String: Any] {
        ["id": String(transaction.id), "productId": transaction.productID]
    }

    @MainActor private static func manage() async throws {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        guard let scene else { throw HostFailure(message: "The app has no window to show the App Store in.") }
        try await AppStore.showManageSubscriptions(in: scene)
    }

    /// Calls `changed` for each transaction the App Store hands the app while it runs: a renewal, an approved Ask to
    /// Buy, a purchase made on another device. Listen from launch, or StoreKit holds them back.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                guard case .verified = result else { continue }
                await changed()
            }
        }
    }
}
