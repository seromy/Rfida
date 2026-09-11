import Foundation

struct InventorySubmission: Codable {
    var staffId: Int
    var batchLabel: String
    var scannedEpcs: [String]
    var timestamp: Date
}
