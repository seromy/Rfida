import Foundation

/// 情景4:定期盤點。方案書7.5提醒讀寫模組tag buffer上限約200個標籤,
/// 接近上限時anti-collision機制會開始漏讀,實務上可能需要分區/分批,
/// 所以呢度用batchLabel記錄批次,並喺接近上限時顯示提示。
@MainActor
final class InventoryViewModel: ObservableObject {
    static let tagBufferWarningThreshold = 180

    @Published var selectedStaffId: Int?
    @Published var batchLabel: String = ""
    @Published var scannedEPCs: Set<String> = []
    @Published var isSubmitting = false
    @Published var lastMessage: String?
    @Published var lastError: String?

    private let api = APIClient.shared

    var isNearBufferLimit: Bool { scannedEPCs.count >= Self.tagBufferWarningThreshold }

    func handle(reads: [TagRead]) {
        for read in reads { scannedEPCs.insert(read.epc) }
    }

    func notSeen(in masterData: MasterDataStore) -> [Equipment] {
        masterData.equipment.filter { !scannedEPCs.contains($0.epc.uppercased()) }
    }

    func unknownEPCs(in masterData: MasterDataStore) -> [String] {
        scannedEPCs.filter { masterData.equipmentByEPC[$0] == nil }.sorted()
    }

    func reset() {
        scannedEPCs.removeAll()
        batchLabel = ""
    }

    func submit() async {
        guard let staffId = selectedStaffId else { lastError = "請先選擇員工"; return }
        guard !scannedEPCs.isEmpty else { lastError = "未掃描到任何標籤"; return }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }
        let submission = InventorySubmission(
            staffId: staffId,
            batchLabel: batchLabel.isEmpty ? "未命名批次" : batchLabel,
            scannedEpcs: Array(scannedEPCs),
            timestamp: Date()
        )
        do {
            try await api.submitInventory(submission)
            lastMessage = "已提交盤點批次,共 \(scannedEPCs.count) 件"
            reset()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "提交失敗"
        }
    }
}
