import Foundation

/// 示範模式(Demo Mode)嘅假資料,對應 server/rfida_server/seed.py 嘅示範資料,
/// 令冇後台伺服器、冇RFID手提機硬件都可以完整行一次四大使用情景。
enum DemoData {
    static let equipment: [Equipment] = [
        Equipment(id: 1, epc: "E2801160600002042BB8A1C1", name: "Sony A7IV 機身", category: "機身", serialNumber: "SN-0001", status: .inStock, lastSeenAt: Date()),
        Equipment(id: 2, epc: "E2801160600002042BB8A1C2", name: "Sony A7IV 機身", category: "機身", serialNumber: "SN-0002", status: .checkedOut, lastSeenAt: Date()),
        Equipment(id: 3, epc: "E2801160600002042BB8A1C3", name: "Sony FE 24-70mm F2.8", category: "鏡頭", serialNumber: "SN-1001", status: .checkedOut, lastSeenAt: Date()),
        Equipment(id: 4, epc: "E2801160600002042BB8A1C4", name: "Sony FE 70-200mm F2.8", category: "鏡頭", serialNumber: "SN-1002", status: .inStock, lastSeenAt: Date()),
        Equipment(id: 5, epc: "E2801160600002042BB8A1C5", name: "Godox AD200 閃光燈", category: "燈光", serialNumber: "SN-2001", status: .inStock, lastSeenAt: Date()),
        Equipment(id: 6, epc: "E2801160600002042BB8A1C6", name: "Manfrotto 三腳架", category: "支架", serialNumber: "SN-3001", status: .missing, lastSeenAt: Date()),
    ]

    static let staff: [Staff] = [
        Staff(id: 1, name: "陳大文"),
        Staff(id: 2, name: "李小明"),
        Staff(id: 3, name: "黃美玲"),
    ]

    static let openJob = Job(id: 1, name: "2026-09-12 婚禮攝影(示範)", date: Date().addingTimeInterval(86_400), status: .open)

    /// 情景2出Job時已帶走嘅器材,作為情景3「應有清單」嘅比對基準。
    static let openJobExpectedItems: [MovementItem] = [
        MovementItem(epc: "E2801160600002042BB8A1C2", equipmentId: 2),
        MovementItem(epc: "E2801160600002042BB8A1C3", equipmentId: 3),
    ]

    /// 情景1(錄入新標籤)示範用嘅「未登記」EPC,模擬將新器材逐件放近讀寫頭。
    static let unregisteredEPCs = [
        "E2801160600002042BB8A2D1",
        "E2801160600002042BB8A2D2",
        "E2801160600002042BB8A2D3",
        "E2801160600002042BB8A2D4",
    ]
}
