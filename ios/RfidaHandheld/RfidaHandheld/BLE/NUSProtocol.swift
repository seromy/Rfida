import CoreBluetooth
import Foundation

/// ESP32 韌體以 Nordic UART Service (NUS) 模式同手機交換一行一行嘅 ASCII 文字(LF 結尾)。
/// 呢個常數同 ESP32 韌體(Arduino/C++)嘅 BLE service/characteristic UUID 要完全一致。
/// 完整合約(v2:手動掃描、無讀取自動停止、CFG2 設定)見 `docs/BLE_PROTOCOL.md`。
enum NUSProtocol {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX:手機 -> ESP32(寫入模式/設定指令)
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX:ESP32 -> 手機(notify,傳送EPC、@STATE 狀態快照同 @CFG2 設定回覆)
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
}

/// 掃描模式指令,經 RX characteristic 傳俾 ESP32 韌體。
/// REGISTER/BATCH 都係「開始掃描」,用同一個全域功率設定(韌體唔會按模式自動加大功率);
/// IDLE 係「停止掃描」。
enum ScanMode: String {
    case idle = "MODE:IDLE"
    case register = "MODE:REGISTER"
    case batch = "MODE:BATCH"
}

/// 韌體大約每 500ms 發一次嘅 `@STATE:<狀態>` 快照。快照冇 request ID,只適用於當前連接,
/// 亦唔保證每個短暫狀態都會出現(例如 STARTING 可能一閃即過)。
enum ReaderState: String, Equatable {
    case unknown = "UNKNOWN"
    case stopping = "STOPPING"
    case ready = "READY"
    case starting = "STARTING"
    case scanning = "SCANNING"
    case fault = "FAULT"
    case configuring = "CONFIGURING"
}

/// 讀卡器設定:原始功率等級(唔係實測 dBm)同「無讀取自動停止」秒數。
struct ReaderSettings: Equatable {
    let power: Int
    let idleSeconds: Int
}

enum ReaderSettingsLimits {
    /// App 容許使用者編輯/套用嘅功率範圍。
    static let editablePower = 10...26
    /// 讀取(GET)時接受嘅實際功率範圍;例如舊設定 33 都要照實顯示。
    static let reportedPower = 0...33
    static let idleSeconds = 1...60
    static let defaultPower = 20
    static let defaultIdleSeconds = 10
    /// App 用嘅 request ID 範圍(韌體接受 1...65535)。
    static let requestIDs = 1...999
}

/// 手機 -> ESP32 嘅指令。所有指令都由呢度產生,App 唔會直接發送讀寫模組嘅二進制指令。
enum ReaderCommand: Equatable {
    case mode(ScanMode)
    case getSettings(id: Int)
    case setSettings(id: Int, settings: ReaderSettings)

    /// 唔包括結尾 LF。
    var line: String {
        switch self {
        case .mode(let mode):
            return mode.rawValue
        case .getSettings(let id):
            return "CFG2:GET:\(id)"
        case .setSettings(let id, let settings):
            // 秒數單位係「秒」,唔係毫秒;同舊 CFG(毫秒)協議刻意唔兼容。
            return "CFG2:SET:\(id):\(settings.power):\(settings.idleSeconds)"
        }
    }

    /// 實際寫入 RX 嘅 bytes(結尾係真正嘅 LF 字元)。最長嘅 `CFG2:SET:999:26:60\n` 係 19 bytes。
    var data: Data { Data((line + "\n").utf8) }
}

/// `@CFG2:<id>:OK:<power>:<idleSeconds>` 或 `@CFG2:<id>:ERR:<reason>`。
enum SettingsReply: Equatable {
    case ok(id: Int, settings: ReaderSettings)
    case error(id: Int, reason: String)

    var id: Int {
        switch self {
        case .ok(let id, _), .error(let id, _): return id
        }
    }
}

/// 一行 TX 文字嘅分類。控制行(以 `@` 開頭)一定會喺 EPC 解析之前處理,
/// 所以 `@CFG2`/`@STATE`(或者任何未知嘅 `@` 行)永遠唔會被當成標籤。
enum NUSLine: Equatable {
    case settings(SettingsReply)
    case state(ReaderState)
    case tag(epc: String, rssi: Int?)
    case ignored

    static func classify(_ rawLine: String) -> NUSLine {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .ignored }

        if line.hasPrefix("@") {
            if line.hasPrefix("@CFG2:") {
                return parseSettingsReply(line).map(NUSLine.settings) ?? .ignored
            }
            if line.hasPrefix("@STATE:") {
                return ReaderState(rawValue: String(line.dropFirst("@STATE:".count))).map(NUSLine.state) ?? .ignored
            }
            // 包括舊 `@CFG:` 回覆:刻意唔支援,亦唔會 fallback。
            return .ignored
        }

        return parseTag(line) ?? .ignored
    }

    /// 解析 EPC 行,格式為 "EPC" 或 "EPC,RSSI"(沿用原有 legacy 解析規則)。
    /// 注意(方案書第9節):EPC喺讀寫模組frame入面嘅實際offset需要用實物校準,
    /// 校準應該喺ESP32韌體層做好,呢邊假設收到嘅已經係乾淨嘅EPC hex string。
    static func parseTag(_ line: String) -> NUSLine? {
        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let epcPart = parts.first, isValidEPCHex(epcPart) else { return nil }

        var rssi: Int?
        if parts.count > 1 { rssi = Int(parts[1]) }

        return .tag(epc: epcPart.uppercased(), rssi: rssi)
    }

    private static func isValidEPCHex(_ s: String) -> Bool {
        // 韌體最多轉發 64 byte EPC(128 個 hex 字元)。
        guard s.count >= 8, s.count <= 128, s.count % 2 == 0 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }

    private static func parseSettingsReply(_ line: String) -> SettingsReply? {
        let parts = line.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "@CFG2", let id = strictDecimal(parts[1]), id >= 1 else { return nil }
        switch parts[2] {
        case "OK":
            guard parts.count == 5, let power = strictDecimal(parts[3]), let seconds = strictDecimal(parts[4]) else { return nil }
            return .ok(id: id, settings: ReaderSettings(power: power, idleSeconds: seconds))
        case "ERR":
            let reason = parts[3]
            guard parts.count == 4, !reason.isEmpty, reason.count <= 32,
                  reason.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) else { return nil }
            return .error(id: id, reason: String(reason))
        default:
            return nil
        }
    }

    /// 嚴格十進制整數:只接受數字、冇正負號、冇多餘前導零、最大 65535。
    static func strictDecimal(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= 5, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        guard s.count == 1 || s.first != "0" else { return nil }
        guard let value = Int(s), value <= 65_535 else { return nil }
        return value
    }
}

/// 將 BLE notification 重組成完整嘅行。一個 notification 可以只係一行嘅一部分,亦可以包含幾行;
/// 未完嘅尾段會保留到下一個 notification。每行長度有上限,超長行會成行丟棄,避免 buffer 無限增長。
struct NUSLineBuffer {
    static let maxLineBytes = 256

    private var pending: [UInt8] = []
    private var discardingOverlongLine = false

    /// 回傳完整、非空白嘅行(未 trim);含非 ASCII/控制字元嘅行會被丟棄。
    mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if !discardingOverlongLine, let line = Self.decode(pending) {
                    lines.append(line)
                }
                pending.removeAll(keepingCapacity: true)
                discardingOverlongLine = false
            } else if discardingOverlongLine {
                continue
            } else if pending.count >= Self.maxLineBytes {
                pending.removeAll(keepingCapacity: true)
                discardingOverlongLine = true
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    mutating func reset() {
        pending.removeAll()
        discardingOverlongLine = false
    }

    private static func decode(_ bytes: [UInt8]) -> String? {
        // 容許 CR/TAB(會喺分類時 trim 走),其他控制字元或非 ASCII 一律當損壞行。
        guard bytes.allSatisfy({ ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0D || $0 == 0x09 }) else { return nil }
        let line = String(decoding: bytes, as: UTF8.self)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return line
    }
}
