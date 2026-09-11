import Foundation

/// 情景3:返office前清點(歸還)。核心係將「應有清單」(出Job時登記嘅清單)
/// 同「而家掃到」自動比對,揪出缺件 —— 方案書7.4標註呢個功能原本未實作,建議加。
@MainActor
final class ReturnCheckViewModel: ObservableObject {
    @Published var selectedStaffId: Int?
    @Published var selectedJobId: Int?
    @Published var expectedItems: [MovementItem] = []
    @Published var scannedEPCs: Set<String> = []
    @Published var isLoadingExpected = false
    @Published var isSubmitting = false
    @Published var lastMessage: String?
    @Published var lastError: String?

    private let api = APIClient.shared

    var diff: ReturnDiffResult {
        ReturnDiffEngine.diff(expected: expectedItems, scannedEPCs: scannedEPCs)
    }

    func loadExpectedItems() async {
        guard let jobId = selectedJobId else { return }
        isLoadingExpected = true
        lastError = nil
        defer { isLoadingExpected = false }
        do {
            expectedItems = try await api.fetchExpectedItems(jobId: jobId)
            scannedEPCs.removeAll()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "無法讀取應有清單"
        }
    }

    func handle(reads: [TagRead]) {
        for read in reads {
            scannedEPCs.insert(read.epc)
        }
    }

    func submit() async {
        guard let jobId = selectedJobId else { lastError = "請先選擇 Job"; return }
        guard let staffId = selectedStaffId else { lastError = "請先選擇員工"; return }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }
        let missingEPCs = diff.missing.map { $0.epc }
        let submission = MovementSubmission(jobId: jobId, staffId: staffId, direction: .inbound, epcs: Array(scannedEPCs), missingEpcs: missingEPCs, note: nil)
        do {
            try await api.submitMovement(submission)
            lastMessage = missingEPCs.isEmpty ? "器材已全部歸還" : "已提交,缺少 \(missingEPCs.count) 件器材"
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "提交失敗"
        }
    }
}
