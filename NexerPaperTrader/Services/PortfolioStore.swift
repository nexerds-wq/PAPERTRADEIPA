import Foundation

@MainActor
final class PortfolioStore: ObservableObject {
    @Published var cash: Double = 10_000
    @Published var positions: [Position] = []
    @Published var shortPositions: [ShortPosition] = []
    @Published var orders: [PaperOrder] = []
    @Published var closedTrades: [ClosedTrade] = []
    @Published var closedShortTrades: [ClosedShortTrade] = []

    private let key = "nexer.paper.portfolio.v2"
    private let legacyKey = "nexer.paper.portfolio.v1"

    init() { load() }

    var exposureCount: Int { positions.count + shortPositions.count }

    func reset() {
        cash = 10_000
        positions = []
        shortPositions = []
        orders = []
        closedTrades = []
        closedShortTrades = []
        save()
    }

    func position(for assetID: String) -> Position? {
        positions.first { $0.assetID == assetID }
    }

    func shortPosition(for assetID: String) -> ShortPosition? {
        shortPositions.first { $0.assetID == assetID }
    }

    func hasExposure(_ assetID: String) -> Bool {
        position(for: assetID) != nil || shortPosition(for: assetID) != nil
    }

    func portfolioValue(quotes: [String: Quote]) -> Double {
        let longValue = positions.reduce(0.0) { partial, pos in
            partial + pos.quantity * (quotes[pos.assetID]?.price ?? pos.averagePrice)
        }

        let shortEquity = shortPositions.reduce(0.0) { partial, pos in
            let mark = quotes[pos.assetID]?.price ?? pos.averagePrice
            let unrealized = (pos.averagePrice - mark) * pos.quantity
            return partial + pos.margin + unrealized
        }

        return cash + longValue + shortEquity
    }

    func placeMarketOrder(asset: Asset, side: OrderSide, dollars: Double?, quantity explicitQty: Double?, price: Double) throws {
        guard price > 0 else { throw TradeError.invalidPrice }
        let qty = explicitQty ?? ((dollars ?? 0) / price)
        guard qty > 0 else { throw TradeError.invalidQuantity }
        try executeFill(asset: asset, side: side, quantity: qty, price: price)
        orders.insert(.init(id: UUID(), assetID: asset.id, side: side, type: .market, quantity: qty, requestedPrice: nil, fillPrice: price, status: .filled, createdAt: Date()), at: 0)
        save()
    }

    func openShort(asset: Asset, dollars: Double?, quantity explicitQty: Double?, price: Double) throws {
        guard price > 0 else { throw TradeError.invalidPrice }
        let qty = explicitQty ?? ((dollars ?? 0) / price)
        guard qty > 0 else { throw TradeError.invalidQuantity }
        guard position(for: asset.id) == nil else { throw TradeError.oppositePositionExists }

        let requiredMargin = qty * price
        guard requiredMargin <= cash + 0.0001 else { throw TradeError.notEnoughCash }
        cash -= requiredMargin

        if let index = shortPositions.firstIndex(where: { $0.assetID == asset.id }) {
            let old = shortPositions[index]
            let newQty = old.quantity + qty
            shortPositions[index].averagePrice = ((old.quantity * old.averagePrice) + (qty * price)) / newQty
            shortPositions[index].quantity = newQty
            shortPositions[index].margin += requiredMargin
        } else {
            shortPositions.append(ShortPosition(assetID: asset.id, quantity: qty, averagePrice: price, margin: requiredMargin))
        }

        orders.insert(.init(id: UUID(), assetID: asset.id, side: .sell, type: .market, quantity: qty, requestedPrice: nil, fillPrice: price, status: .filled, createdAt: Date()), at: 0)
        save()
    }

    func coverShort(asset: Asset, quantity explicitQty: Double? = nil, price: Double) throws {
        guard price > 0 else { throw TradeError.invalidPrice }
        guard let index = shortPositions.firstIndex(where: { $0.assetID == asset.id }) else { throw TradeError.noShortPosition }

        let held = shortPositions[index]
        let qty = explicitQty ?? held.quantity
        guard qty > 0 else { throw TradeError.invalidQuantity }
        guard qty <= held.quantity + 0.0000001 else { throw TradeError.notEnoughShares }

        let fraction = min(1, qty / held.quantity)
        let releasedMargin = held.margin * fraction
        let realized = (held.averagePrice - price) * qty
        cash += releasedMargin + realized

        closedShortTrades.insert(.init(id: UUID(), assetID: asset.id, quantity: qty, averageShortPrice: held.averagePrice, coverPrice: price, realizedPL: realized, closedAt: Date()), at: 0)
        orders.insert(.init(id: UUID(), assetID: asset.id, side: .buy, type: .market, quantity: qty, requestedPrice: nil, fillPrice: price, status: .filled, createdAt: Date()), at: 0)

        shortPositions[index].quantity -= qty
        shortPositions[index].margin -= releasedMargin
        if shortPositions[index].quantity < 0.0000001 {
            shortPositions.remove(at: index)
        }
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

    /// Evaluates manual long-only limit orders using current market quotes.
    /// Automated supply/demand trades use immediate paper fills instead.
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
                orders[index] = PaperOrder(id: orders[index].id, assetID: orders[index].assetID, side: orders[index].side, type: orders[index].type, quantity: orders[index].quantity, requestedPrice: orders[index].requestedPrice, fillPrice: q.price, status: .filled, createdAt: orders[index].createdAt)
                changed = true
            } catch {
                // Keep it open so the user can cancel it.
            }
        }

        if changed { save() }
    }

    private func executeFill(asset: Asset, side: OrderSide, quantity qty: Double, price: Double) throws {
        switch side {
        case .buy:
            guard shortPosition(for: asset.id) == nil else { throw TradeError.oppositePositionExists }
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
        let state = SavedState(cash: cash, positions: positions, shortPositions: shortPositions, orders: orders, closedTrades: closedTrades, closedShortTrades: closedShortTrades)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let state = try? JSONDecoder().decode(SavedState.self, from: data) {
            apply(state)
            return
        }

        if let data = UserDefaults.standard.data(forKey: legacyKey),
           let state = try? JSONDecoder().decode(LegacySavedState.self, from: data) {
            cash = state.cash
            positions = state.positions
            orders = state.orders
            closedTrades = state.closedTrades
            shortPositions = []
            closedShortTrades = []
            save()
        }
    }

    private func apply(_ state: SavedState) {
        cash = state.cash
        positions = state.positions
        shortPositions = state.shortPositions ?? []
        orders = state.orders
        closedTrades = state.closedTrades
        closedShortTrades = state.closedShortTrades ?? []
    }

    private struct SavedState: Codable {
        let cash: Double
        let positions: [Position]
        let shortPositions: [ShortPosition]?
        let orders: [PaperOrder]
        let closedTrades: [ClosedTrade]
        let closedShortTrades: [ClosedShortTrade]?
    }

    private struct LegacySavedState: Codable {
        let cash: Double
        let positions: [Position]
        let orders: [PaperOrder]
        let closedTrades: [ClosedTrade]
    }
}

enum TradeError: LocalizedError {
    case invalidPrice
    case invalidQuantity
    case notEnoughCash
    case noPosition
    case noShortPosition
    case notEnoughShares
    case oppositePositionExists

    var errorDescription: String? {
        switch self {
        case .invalidPrice: return "Price is unavailable."
        case .invalidQuantity: return "Enter an amount greater than zero."
        case .notEnoughCash: return "You do not have enough buying power."
        case .noPosition: return "You do not own this asset."
        case .noShortPosition: return "You do not have a short position in this asset."
        case .notEnoughShares: return "You are trying to close more than you hold."
        case .oppositePositionExists: return "Close the opposite position first."
        }
    }
}
