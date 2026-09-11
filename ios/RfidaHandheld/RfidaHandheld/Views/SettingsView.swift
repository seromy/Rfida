import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.backendBaseURL) private var backendBaseURL: String = ""
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore

    var body: some View {
        Form {
            Section("後台伺服器") {
                TextField("http://192.168.1.50:5000", text: $backendBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("重新載入資料") {
                    Task { await masterData.refreshAll() }
                }
            }

            Section("藍牙裝置") {
                TextField("裝置名稱過濾(例:RFID)", text: $ble.namePrefixFilter)
                    .onChange(of: ble.namePrefixFilter) { newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKey.blePrefix)
                    }
            }

            Section("關於") {
                LabeledContent("App 版本", value: Bundle.main.appVersionString)
                Text("此App冇獨立登入/權限系統,假設喺辦公室內部信任網絡環境使用(方案書第9節)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
    }
}
