import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.backendBaseURL) private var backendBaseURL: String = ""
    @AppStorage(SettingsKey.scanSoundMuted) private var scanSoundMuted: Bool = false
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

            Section("掃描提示聲") {
                Toggle("靜音模式(關閉掃描提示聲)", isOn: $scanSoundMuted)
                Text("每次成功掃描到新標籤都會發出提示聲,呢個聲音唔跟手機側邊嘅靜音撥掣,只受呢度嘅開關控制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("藍牙裝置") {
                TextField("裝置名稱過濾(例:RFID)", text: $ble.namePrefixFilter)
                    .onChange(of: ble.namePrefixFilter) { newValue in
                        UserDefaults.standard.set(newValue, forKey: SettingsKey.blePrefix)
                    }
            }

            Section("關於") {
                LabeledContent("App 版本", value: Bundle.main.appVersionString)
            }
        }
        .navigationTitle("設定")
    }
}
