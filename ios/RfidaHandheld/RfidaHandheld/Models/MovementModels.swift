import Foundation

enum MovementDirection: String, Codable {
    case out
    case inbound = "in"
}

struct MovementItem: Codable, Hashable {
    var epc: String
    var equipmentId: Int?
}

struct MovementSubmission: Codable {
    var jobId: Int
    var staffId: Int
    var direction: MovementDirection
    var epcs: [String]
    var missingEpcs: [String]?
    var note: String?
}
