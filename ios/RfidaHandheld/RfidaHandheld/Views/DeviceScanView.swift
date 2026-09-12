import SwiftUI

struct DeviceScanView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        List {
            Section {
                ConnectionStatusBadge()
                if case .connected = ble.state {
                    Button("中斷連接", role: .destructive) { ble.disconnect() }
                }
            }

            if ble.isDemoMode {
                Section("示範模式") {
                    Text("示範模式已啟用,已自動連接示範手提機,唔需要搜尋真實裝置。可到「設定」關閉示範模式。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("附近裝置") {
                    if ble.discoveredDevices.isEmpty {
                        Text("未搜尋到裝置,請確認手提機已開機並在範圍內。").foregroundStyle(.secondary)
                    }
                    ForEach(ble.discoveredDevices) { device in
                        Button {
                            ble.connect(device)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("連接 RFID 手提機")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("搜尋") { ble.startScan() }
            }
        }
        .onAppear { ble.startScan() }
        .onDisappear { ble.stopScan() }
    }
}
