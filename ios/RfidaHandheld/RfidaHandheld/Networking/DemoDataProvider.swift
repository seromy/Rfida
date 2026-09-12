import Foundation

/// 示範模式(Demo Mode)嘅假後台:APIClient喺 SettingsKey.demoMode 開啟時
/// 改用呢個記憶體內嘅假資料,唔會發出任何網絡請求,亦唔需要真實後台伺服器。
actor DemoDataProvider {
    static let shared = DemoDataProvider()

    private var equipment = DemoData.equipment
    private var expectedItemsByJob: [Int: [MovementItem]] = [DemoData.openJob.id: DemoData.openJobExpectedItems]

    func fetchEquipment() -> [Equipment] { equipment }
    func fetchStaff() -> [Staff] { DemoData.staff }
    func fetchOpenJobs() -> [Job] { [DemoData.openJob] }
    func fetchExpectedItems(jobId: Int) -> [MovementItem] { expectedItemsByJob[jobId] ?? [] }

    func registerTag(epc: String, name: String, category: String, serialNumber: String?) -> Equipment {
        let newItem = Equipment(
            id: (equipment.map(\.id).max() ?? 0) + 1,
            epc: epc,
            name: name,
            category: category,
            serialNumber: serialNumber,
            status: .inStock,
            lastSeenAt: Date()
        )
        equipment.append(newItem)
        return newItem
    }

    func submitMovement(_ submission: MovementSubmission) {
        for epc in submission.epcs {
            guard let idx = equipment.firstIndex(where: { $0.epc.uppercased() == epc.uppercased() }) else { continue }
            equipment[idx].status = submission.direction == .out ? .checkedOut : .inStock
            equipment[idx].lastSeenAt = Date()
        }
        if submission.direction == .out {
            expectedItemsByJob[submission.jobId] = submission.epcs.map { epc in
                MovementItem(epc: epc, equipmentId: equipment.first { $0.epc.uppercased() == epc.uppercased() }?.id)
            }
        }
    }

    func submitInventory(_ submission: InventorySubmission) {
        for epc in submission.scannedEpcs {
            guard let idx = equipment.firstIndex(where: { $0.epc.uppercased() == epc.uppercased() }) else { continue }
            equipment[idx].lastSeenAt = submission.timestamp
        }
    }
}
