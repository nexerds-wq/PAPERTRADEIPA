import Foundation

enum OrderSide: String, Codable { case buy, sell }
enum OrderType: String, Codable, CaseIterable, Identifiable {
    case market = "Market"
    case limit = "Limit"
    case stop = "Stop"
    var id: String { rawValue }
}

enum OrderStatus: String, Codable { case filled, open, cancelled }

struct Position: Identifiable, Codable, Hashable {
    var id: String { assetID }
    let assetID: String
    var quantity: Double
    var averagePrice: Double
}

struct PaperOrder: Identifiable, Codable, Hashable {
    let id: UUID
    let assetID: String
    let side: OrderSide
    let type: OrderType
    let quantity: Double
    let requestedPrice: Double?
    let fillPrice: Double?
    let status: OrderStatus
    let createdAt: Date
}

struct ClosedTrade: Identifiable, Codable, Hashable {
    let id: UUID
    let assetID: String
    let quantity: Double
    let averageBuyPrice: Double
    let sellPrice: Double
    let realizedPL: Double
    let closedAt: Date
}
