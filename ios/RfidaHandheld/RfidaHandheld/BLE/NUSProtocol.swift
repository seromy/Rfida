import CoreBluetooth
import Foundation

/// ESP32 韌體以 Nordic UART Service (NUS) 模式向手機傳送已讀到嘅 EPC。
/// 呢個常數同 ESP32 韌體(Arduino/C++)嘅 BLE service/characteristic UUID 要完全一致。
enum NUSProtocol {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX:手機 -> ESP32(寫入模式指令)
    static let rxCharacteristicUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX:ESP32 -> 手機(notify,傳送EPC)
    static let txCharacteristicUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
}

/// 掃描模式指令,經 RX characteristic 傳俾 ESP32 韌體。
/// 對應方案書7.1-7.2:情景1(register)需要低功率、單標籤隔離;
/// 情景2/3/4(batch)需要盡量一次過讀盡成批標籤。
/// 實際功率/AT command 由韌體實作,呢邊淨係負責通知韌體而家係邊個模式。
enum ScanMode: String {
    case idle = "MODE:IDLE"
    case register = "MODE:REGISTER"
    case batch = "MODE:BATCH"
}

/// 解析經 BLE 收到嘅 UART 串流。假設協議為:每讀到一個標籤,韌體傳送一行文字,
/// 格式為 "EPC" 或 "EPC,RSSI",以 "\n" 分隔。多個標籤可以喺同一個BLE封包內用多行傳送,
/// 亦要處理封包中途斷開一行嘅情況(靠buffer累積)。
/// 注意(方案書第9節):EPC喺讀寫模組frame入面嘅實際offset需要用實物校準,
/// 校準應該喺ESP32韌體層做好,呢邊假設收到嘅已經係乾淨嘅EPC hex string。
struct NUSFrameParser {
    private var buffer = ""

    mutating func feed(_ data: Data) -> [TagRead] {
        guard let chunk = String(data: data, encoding: .utf8) else { return [] }
        buffer += chunk

        var reads: [TagRead] = []
        while let newlineRange = buffer.range(of: "\n") {
            let rawLine = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
            if let read = Self.parseLine(rawLine) {
                reads.append(read)
            }
        }
        return reads
    }

    static func parseLine(_ rawLine: String) -> TagRead? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let epcPart = parts.first, isValidEPCHex(epcPart) else { return nil }

        var rssi: Int?
        if parts.count > 1 { rssi = Int(parts[1]) }

        return TagRead(epc: epcPart.uppercased(), rssi: rssi, timestamp: Date())
    }

    private static func isValidEPCHex(_ s: String) -> Bool {
        guard s.count >= 8, s.count % 2 == 0 else { return false }
        return s.allSatisfy { $0.isHexDigit }
    }
}
