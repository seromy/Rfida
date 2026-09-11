import SwiftUI

struct HomeView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore

    var body: some View {
        NavigationStack {
            List {
                Section("裝置連接") {
                    NavigationLink {
                        DeviceScanView()
                    } label: {
                        HStack {
                            Text("RFID 手提機")
                            Spacer()
                            ConnectionStatusBadge()
                        }
                    }
                }

                Section("資料概況") {
                    LabeledContent("器材總數", value: "\(masterData.equipment.count)")
                    LabeledContent("員工人數", value: "\(masterData.staff.count)")
                    LabeledContent("進行中 Job", value: "\(masterData.openJobs.count)")
                    if masterData.isLoading {
                        ProgressView()
                    }
                    if let error = masterData.lastError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                    Button("重新整理") {
                        Task { await masterData.refreshAll() }
                    }
                }

                Section {
                    Text("四大使用情景已分佈喺下方分頁:錄入標籤、出Job登記、歸還清點、定期盤點。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("RFID 器材管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }
}
