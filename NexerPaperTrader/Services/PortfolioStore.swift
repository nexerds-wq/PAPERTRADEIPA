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

        orders.insert(.init(id: UUID(), assetID: asset.id, side: side, type: .market, quantity: qty, requestedPrice: nil, fillPrice: price, status: .filled, createdAt: Date()), at: 0)
        save()
    }

    private func save() {
        let state = SavedState(cash: cash, positions: positions, orders: orders, closedTrades: closedTrades)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key), let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        cash = state.cash; positions = state.positions; orders = state.orders; closedTrades = state.closedTrades
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
