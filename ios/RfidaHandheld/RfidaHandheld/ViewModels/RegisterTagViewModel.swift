import Foundation

/// 情景1:錄入新標籤。方案書要求「必須嚴格隔離,確保讀寫頭附近淨係得一個標籤」,
/// 對應7.3「軟件多重標籤警告」:偵測到多過一個未登記標籤時停用配對操作。
@MainActor
final class RegisterTagViewModel: ObservableObject {
    @Published var detectedEPCs: [String] = []
    @Published var name: String = ""
    @Published var category: String = ""
    @Published var serialNumber: String = ""
    @Published var isSubmitting = false
    @Published var lastMessage: String?
    @Published var lastError: String?

    private let api = APIClient.shared
    private var knownEPCs: Set<String> = []

    var hasMultipleTags: Bool { detectedEPCs.count > 1 }
    var singleDetectedEPC: String? { detectedEPCs.count == 1 ? detectedEPCs[0] : nil }

    func updateKnownEPCs(_ epcs: Set<String>) {
        knownEPCs = epcs
    }

    func handle(reads: [TagRead]) {
        for read in reads where !knownEPCs.contains(read.epc) {
            if !detectedEPCs.contains(read.epc) {
                detectedEPCs.append(read.epc)
                ScanSoundPlayer.shared.playScanBeep()
            }
        }
    }

    func clearDetected() {
        detectedEPCs.removeAll()
    }

    func submit(masterData: MasterDataStore) async {
        guard let epc = singleDetectedEPC else { return }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = "請先輸入器材名稱"
            return
        }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }
        do {
            let equipment = try await api.registerTag(
                epc: epc,
                name: name,
                category: category.isEmpty ? "未分類" : category,
                serialNumber: serialNumber.isEmpty ? nil : serialNumber
            )
            masterData.addRegisteredEquipment(equipment)
            knownEPCs.insert(epc)
            detectedEPCs.removeAll()
            name = ""
            category = ""
            serialNumber = ""
            lastMessage = "已登記:\(equipment.name)(EPC \(epc))"
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "登記失敗"
        }
    }
}
