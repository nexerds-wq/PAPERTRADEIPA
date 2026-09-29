import Foundation

@MainActor
final class PortfolioStore: ObservableObject {
    @Published var cash: Double = 10_000
    @Published var positions: [Position] = []
    @Published var orders: [PaperOrder] = []
    @Published var closedTrades: [ClosedTrade] = []

    private let key = "nexer.paper.portfolio.v1"

    init() { load() }

    func reset() {
        cash = 10_000
        positions = []
        orders = []
        closedTrades = []
        save()
    }

    func position(for assetID: String) -> Position? { positions.first { $0.assetID == assetID } }

    func portfolioValue(quotes: [String: Quote]) -> Double {
        cash + positions.reduce(0) { partial, pos in
            partial + pos.quantity * (quotes[pos.assetID]?.price ?? pos.averagePrice)
        }
    }

    func placeMarketOrder(asset: Asset, side: OrderSide, dollars: Double?, quantity explicitQty: Double?, price: Double) throws {
        guard price > 0 else { throw TradeError.invalidPrice }
        let qty = explicitQty ?? ((dollars ?? 0) / price)
        guard qty > 0 else { throw TradeError.invalidQuantity }
        try executeFill(asset: asset, side: side, quantity: qty, price: price)
        orders.insert(.init(id: UUID(), assetID: asset.id, side: side, type: .market, quantity: qty, requestedPrice: nil, fillPrice: price, status: .filled, createdAt: Date()), at: 0)
        save()
    }

    func placeLimitOrder(asset: Asset, side: OrderSide, dollars: Double?, quantity explicitQty: Double?, limitPrice: Double) throws {
        guard limitPrice > 0 else { throw TradeError.invalidPrice }
        let qty = explicitQty ?? ((dollars ?? 0) / limitPrice)
        guard qty > 0 else { throw TradeError.invalidQuantity }

        if side == .buy {
            let estimatedCost = qty * limitPrice
            guard estimatedCost <= cash + 0.0001 else { throw TradeError.notEnoughCash }
        } else {
            guard let held = position(for: asset.id) else { throw TradeError.noPosition }
            guard qty <= held.quantity + 0.0000001 else { throw TradeError.notEnoughShares }
        }

        orders.insert(.init(id: UUID(), assetID: asset.id, side: side, type: .limit, quantity: qty, requestedPrice: limitPrice, fillPrice: nil, status: .open, createdAt: Date()), at: 0)
        save()
    }

    @discardableResult
    func cancelOrder(id: UUID) -> Bool {
        guard let index = orders.firstIndex(where: { $0.id == id }), orders[index].status == .open else { return false }
        orders[index].status = .cancelled
        save()
        return true
    }

    func cancelAllOpenOrders() {
        var changed = false
        for index in orders.indices where orders[index].status == .open {
            orders[index].status = .cancelled
            changed = true
        }
        if changed { save() }
    }

    /// Evaluates open paper limit orders using current market quotes.
    /// This never sends an order to a brokerage.
    func evaluateOpenOrders(quotes: [String: Quote]) {
        var changed = false

        for index in orders.indices {
            guard orders[index].status == .open,
                  let q = quotes[orders[index].assetID],
                  let requested = orders[index].requestedPrice,
                  let asset = Asset.universe.first(where: { $0.id == orders[index].assetID }) else { continue }

            let shouldFill: Bool
            switch orders[index].side {
            case .buy: shouldFill = q.price <= requested
            case .sell: shouldFill = q.price >= requested
            }

            guard shouldFill else { continue }

            do {
                try executeFill(asset: asset, side: orders[index].side, quantity: orders[index].quantity, price: q.price)
                orders[index] = PaperOrder(
                    id: orders[index].id,
                    assetID: orders[index].assetID,
                    side: orders[index].side,
                    type: orders[index].type,
                    quantity: orders[index].quantity,
                    requestedPrice: orders[index].requestedPrice,
                    fillPrice: q.price,
                    status: .filled,
                    createdAt: orders[index].createdAt
                )
                changed = true
            } catch {
                // If cash or shares are no longer available, keep the order open so the user can cancel it.
            }
        }

        if changed { save() }
    }

    private func executeFill(asset: Asset, side: OrderSide, quantity qty: Double, price: Double) throws {
        switch side {
        case .buy:
            let cost = qty * price
            guard cost <= cash + 0.0001 else { throw TradeError.notEnoughCash }
            cash -= cost
            if let index = positions.firstIndex(where: { $0.assetID == asset.id }) {
                let old = positions[index]
                let newQty = old.quantity + qty
                positions[index].averagePrice = ((old.quantity * old.averagePrice) + cost) / newQty
                positions[index].quantity = newQty
            } else {
                positions.append(Position(assetID: asset.id, quantity: qty, averagePrice: price))
            }

        case .sell:
            guard let index = positions.firstIndex(where: { $0.assetID == asset.id }) else { throw TradeError.noPosition }
            let held = positions[index]
            guard qty <= held.quantity + 0.0000001 else { throw TradeError.notEnoughShares }
            cash += qty * price
            let realized = qty * (price - held.averagePrice)
            closedTrades.insert(.init(id: UUID(), assetID: asset.id, quantity: qty, averageBuyPrice: held.averagePrice, sellPrice: price, realizedPL: realized, closedAt: Date()), at: 0)
            positions[index].quantity -= qty
            if positions[index].quantity < 0.0000001 { positions.remove(at: index) }
        }
    }

    private func save() {
        let state = SavedState(cash: cash, positions: positions, orders: orders, closedTrades: closedTrades)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        cash = state.cash
        positions = state.positions
        orders = state.orders
        closedTrades = state.closedTrades
    }

    private struct SavedState: Codable {
        let cash: Double
        let positions: [Position]
        let orders: [PaperOrder]
        let closedTrades: [ClosedTrade]
    }
}

enum TradeError: LocalizedError {
    case invalidPrice, invalidQuantity, notEnoughCash, noPosition, notEnoughShares
    var errorDescription: String? {
        switch self {
        case .invalidPrice: return "Price is unavailable."
        case .invalidQuantity: return "Enter an amount greater than zero."
        case .notEnoughCash: return "You do not have enough buying power."
        case .noPosition: return "You do not own this asset."
        case .notEnoughShares: return "You are trying to sell more than you own."
        }
    }
}
