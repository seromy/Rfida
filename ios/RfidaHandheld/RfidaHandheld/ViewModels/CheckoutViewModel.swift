import Foundation

/// 情景2:出發前登記(出Job)。方向同情景1相反 —「目標係盡量一次過讀盡成批器材,
/// 防漏讀重要過防多讀」,所以呢度只做批量累積,唔做單/多標籤警告。
@MainActor
final class CheckoutViewModel: ObservableObject {
    @Published var selectedStaffId: Int?
    @Published var selectedJobId: Int?
    @Published var scannedEPCs: [String] = []
    @Published var isSubmitting = false
    @Published var lastMessage: String?
    @Published var lastError: String?

    private let api = APIClient.shared
    private var seen = Set<String>()

    func handle(reads: [TagRead]) {
        for read in reads where !seen.contains(read.epc) {
            seen.insert(read.epc)
            scannedEPCs.append(read.epc)
            ScanSoundPlayer.shared.playScanBeep()
        }
    }

    func remove(epc: String) {
        seen.remove(epc)
        scannedEPCs.removeAll { $0 == epc }
    }

    func reset() {
        scannedEPCs.removeAll()
        seen.removeAll()
    }

    func submit() async {
        guard let staffId = selectedStaffId else {
            lastError = "請先選擇員工"; return
        }
        guard let jobId = selectedJobId else {
            lastError = "請先選擇 Job"; return
        }
        guard !scannedEPCs.isEmpty else {
            lastError = "未掃描到任何器材"; return
        }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }
        let submission = MovementSubmission(jobId: jobId, staffId: staffId, direction: .out, epcs: scannedEPCs, missingEpcs: nil, note: nil)
        do {
            try await api.submitMovement(submission)
            lastMessage = "已提交出Job紀錄,共 \(scannedEPCs.count) 件器材"
            reset()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "提交失敗"
        }
    }
}
