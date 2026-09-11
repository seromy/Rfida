import Foundation

struct TagRead: Identifiable, Hashable {
    let id = UUID()
    let epc: String
    let rssi: Int?
    let timestamp: Date
}
