import Foundation

struct Equipment: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case inStock = "in_stock"
        case checkedOut = "checked_out"
        case missing = "missing"
    }

    let id: Int
    var epc: String
    var name: String
    var category: String
    var serialNumber: String?
    var status: Status
    var lastSeenAt: Date?
}
