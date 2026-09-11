import Foundation

struct Job: Identifiable, Codable, Hashable {
    enum JobStatus: String, Codable {
        case open
        case closed
    }

    let id: Int
    var name: String
    var date: Date?
    var status: JobStatus
}
