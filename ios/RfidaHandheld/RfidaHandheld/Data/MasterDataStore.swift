import Foundation

/// App全域共用嘅器材/員工/Job清單快取,供四大情景畫面查詢EPC對應嘅器材名稱。
@MainActor
final class MasterDataStore: ObservableObject {
    @Published private(set) var equipment: [Equipment] = []
    @Published private(set) var staff: [Staff] = []
    @Published private(set) var openJobs: [Job] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    private let api = APIClient.shared

    var equipmentByEPC: [String: Equipment] {
        Dictionary(equipment.map { ($0.epc.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func refreshAll() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let equipmentTask = api.fetchEquipment()
            async let staffTask = api.fetchStaff()
            async let jobsTask = api.fetchOpenJobs()
            let (e, s, j) = try await (equipmentTask, staffTask, jobsTask)
            equipment = e
            staff = s
            openJobs = j
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "資料載入失敗"
        }
    }

    func addRegisteredEquipment(_ item: Equipment) {
        equipment.append(item)
    }
}
