import SwiftUI

struct ConnectionStatusBadge: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch ble.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        case .poweredOff, .unauthorized: return .red
        case .disconnected: return .gray
        }
    }

    private var text: String {
        switch ble.state {
        case .connected(let name): return "已連接:\(name)"
        case .connecting: return "連接中…"
        case .scanning: return "搜尋裝置中…"
        case .poweredOff: return "藍牙已關閉"
        case .unauthorized: return "未授權使用藍牙"
        case .disconnected: return "未連接"
        }
    }
}
