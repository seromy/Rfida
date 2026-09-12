import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.backendBaseURL) private var backendBaseURL: String = ""
    @AppStorage(SettingsKey.scanSoundMuted) private var scanSoundMuted: Bool = false
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore

    var body: some View {
        Form {
            Section("示範模式") {
                Toggle("示範模式(Demo Mode)", isOn: $ble.isDemoMode)
                Text("開啟後,App會自動連接一個模擬嘅示範手提機,並用內置嘅假器材/員工/Job資料,唔需要真實RFID硬件或後台伺服器,方便展示四大使用情景。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("後台伺服器") {
                TextField("http://192.168.1.50:5000", text: $backendBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(ble.isDemoMode)
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
                    .disabled(ble.isDemoMode)
            }

            Section("關於") {
                LabeledContent("App 版本", value: Bundle.main.appVersionString)
                Text("此App冇獨立登入/權限系統,假設喺辦公室內部信任網絡環境使用(方案書第9節)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("設定")
        .onChange(of: ble.isDemoMode) { _ in
            Task { await masterData.refreshAll() }
        }
    }
}
