import Foundation

/// 讀卡器掃描/設定狀態嘅中文提示(4大情景掃描按鈕同設定畫面共用)。
enum ReaderMessages {
    static let idleResetHelp = "每次讀到標籤都會重新計時，包括同一張標籤。你亦可以隨時按停止掃描。"

    static func settingsFailure(kind: SettingsKind, code: String) -> String {
        let prefix = kind == .get ? "讀取設定失敗" : "套用設定未確認"
        var text = "\(prefix)：\(settingsReason(code))（代碼：\(code)）"
        if kind == .set {
            text += "\n設定可能已部分寫入，請按「讀取設定」核對讀卡器目前數值。"
        }
        return text
    }

    static func settingsReason(_ code: String) -> String {
        switch code {
        case "BUSY": return "讀卡器正在忙（例如掃描或停止中）。請先停止掃描，稍後再試。"
        case "RANGE": return "數值超出範圍（功率 10–26，秒數 1–60）。"
        case "BAD_REPLY": return "讀卡器回覆格式不正確，請檢查讀卡器接線。"
        case "READER_REJECTED": return "讀卡器拒絕了指令。"
        case "UNSUPPORTED_PARAMS": return "讀卡器參數格式不支援。"
        case "BACKUP_FAILED": return "未能備份原有讀卡器參數，已取消寫入。"
        case "STORAGE_UNCONFIRMED": return "未能確認手提機已儲存自動停止秒數。"
        case "READBACK_MISMATCH": return "寫入後讀回的參數不一致。"
        case "TIMEOUT_UNCONFIRMED": return "讀卡器沒有回應。請檢查讀卡器電源和接線。"
        case "LINK_LOST": return "藍牙連線中斷。"
        case "CANCELLED": return "操作已被取消（例如按了停止掃描）。"
        case "NO_REPLY_TIMEOUT": return "8 秒內沒有收到手提機回覆。手提機可能需要更新至支援 CFG2 的韌體，或請檢查讀卡器電源。"
        case "ECHO_MISMATCH": return "手提機回覆的數值與要求不一致。"
        case "INVALID_VALUES": return "手提機回覆的數值無效。"
        case "WRITE_FAILED": return "指令未能經藍牙送出，請檢查連線。"
        default: return "未知錯誤。"
        }
    }

    static func settingsSuccess(_ kind: SettingsKind) -> String {
        kind == .get ? "已讀取讀卡器設定。" : "讀卡器已確認套用設定。"
    }

    static func issue(_ issue: ScanIssue) -> String {
        switch issue {
        case .stopUnconfirmed:
            return "未能確認讀卡器已停止。請再按「停止掃描」；如仍未能確認，請關閉讀卡器電源並檢查接線。"
        case .stateReportsLost:
            return "暫時收不到讀卡器狀態，未能確認是否仍在掃描。已嘗試停止；請再按「停止掃描」或檢查藍牙連線。"
        case .fault:
            return "讀卡器未能確認停止（FAULT）。請檢查讀卡器電源和接線；如情況持續，請關閉讀卡器電源。之後可按「停止掃描」或「讀取設定」重試。"
        case .commandWriteFailed:
            return "指令未能經藍牙送出，未能確認讀卡器狀態。請按「停止掃描」重試或檢查連線。"
        }
    }

    static func notice(_ notice: ScanNotice, idleSeconds: Int?) -> String {
        switch notice {
        case .autoStopped:
            if let idleSeconds {
                return "讀卡器已停止掃描（通常是連續 \(idleSeconds) 秒沒有讀到標籤）。"
            }
            return "讀卡器已停止掃描。"
        case .startNotConfirmed:
            return "未能確認已開始掃描，讀卡器已回到待命。請再按「掃描」。"
        case .recovered:
            return "已確認讀卡器停止並回到待命。"
        }
    }

    /// `nil` 代表唔需要額外說明(例如未連接時,連接狀態徽章已經顯示)。
    static func startBlocker(_ blocker: StartBlocker, isConnected: Bool) -> String? {
        switch blocker {
        case .linkNotReady:
            return isConnected ? "正在連接讀卡器…" : nil
        case .scanActive:
            return nil
        case .settingsInProgress:
            return "正在讀取讀卡器設定…"
        case .settingsUnconfirmed:
            return "未確認讀卡器設定，暫時不能掃描。請確認讀卡器已接通電源，然後按「讀取設定」。"
        case .noStateReport:
            return "未收到讀卡器狀態，請稍候或檢查藍牙連線。"
        case .readerNotReady(let state):
            return "讀卡器準備中（狀態：\(state.rawValue)），請稍候。"
        }
    }
}
