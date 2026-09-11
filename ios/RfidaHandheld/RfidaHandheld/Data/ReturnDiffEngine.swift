import Foundation

struct ReturnDiffResult {
    var matched: [MovementItem]
    var missing: [MovementItem]
    var unexpected: [String]
}

/// 方案書7.4「清單比對」:將出發前登記嘅「應有清單」同返office前實際掃到嘅結果自動比對。
/// 呢個功能原方案書標註為「未實作,建議列入後續開發」,喺呢個App入面實作為情景3嘅核心邏輯。
enum ReturnDiffEngine {
    static func diff(expected: [MovementItem], scannedEPCs: Set<String>) -> ReturnDiffResult {
        var matched: [MovementItem] = []
        var missing: [MovementItem] = []

        for item in expected {
            if scannedEPCs.contains(item.epc.uppercased()) {
                matched.append(item)
            } else {
                missing.append(item)
            }
        }

        let expectedEPCs = Set(expected.map { $0.epc.uppercased() })
        let unexpected = scannedEPCs.subtracting(expectedEPCs)

        return ReturnDiffResult(matched: matched, missing: missing, unexpected: Array(unexpected).sorted())
    }
}
