import Foundation

struct InventorySubmission: Codable {
    var companyId: Int
    var batchLabel: String
    var scannedEpcs: [String]
    var timestamp: Date
}
