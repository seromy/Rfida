import SwiftUI

/// 4大情景畫面共用嘅「開始/停止掃描」按鈕:撳一下開始,再撳一下停止,
/// 亦會顯示`BLEManager.startTagScan`排定嘅1分鐘自動停止倒數。
struct TagScanControlButton: View {
    @EnvironmentObject var ble: BLEManager
    let mode: ScanMode

    var body: some View {
        Section {
            Button {
                if ble.isTagScanning {
                    ble.stopTagScan()
                } else {
                    ble.startTagScan(mode: mode)
                }
            } label: {
                Label(
                    ble.isTagScanning ? "停止掃描" : "開始掃描",
                    systemImage: ble.isTagScanning ? "stop.circle.fill" : "play.circle.fill"
                )
                .foregroundStyle(ble.isTagScanning ? .red : .accentColor)
            }
            .disabled(!ble.isConnected)

            if ble.isTagScanning {
                Text("將於 \(ble.tagScanRemainingSeconds) 秒後自動停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
