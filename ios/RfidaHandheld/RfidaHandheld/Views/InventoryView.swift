import SwiftUI

/// 情景4:定期盤點 — 核實現有器材嘅總數同狀態,留意讀寫模組嘅tag buffer上限。
struct InventoryView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore
    @StateObject private var viewModel = InventoryViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section { ConnectionStatusBadge() }

                TagScanControlButton(mode: .batch)

                Section("盤點批次") {
                    Picker("員工", selection: $viewModel.selectedStaffId) {
                        Text("請選擇").tag(Int?.none)
                        ForEach(masterData.staff) { staff in
                            Text(staff.name).tag(Optional(staff.id))
                        }
                    }
                    TextField("批次標籤(例:A區、鏡頭櫃)", text: $viewModel.batchLabel)
                }

                if viewModel.isNearBufferLimit {
                    Section {
                        Label("已接近讀寫模組嘅tag buffer上限,建議分區/分批盤點", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("掃描狀況") {
                    LabeledContent("已掃描(此批次)", value: "\(viewModel.scannedEPCs.count)")
                    LabeledContent("器材總數", value: "\(masterData.equipment.count)")
                    LabeledContent("未見", value: "\(viewModel.notSeen(in: masterData).count)")
                    let unknown = viewModel.unknownEPCs(in: masterData)
                    if !unknown.isEmpty {
                        LabeledContent("未知標籤", value: "\(unknown.count)")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.submit() }
                    } label: {
                        if viewModel.isSubmitting { ProgressView() } else { Text("提交此批次") }
                    }
                    .disabled(viewModel.isSubmitting || viewModel.scannedEPCs.isEmpty)

                    Button("清空重新盤點", role: .destructive) { viewModel.reset() }
                }

                if let message = viewModel.lastMessage {
                    Text(message).foregroundStyle(.green)
                }
                if let error = viewModel.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("4. 定期盤點")
            .onAppear {
                ble.onTagsRead = { reads in viewModel.handle(reads: reads) }
            }
            .onDisappear {
                ble.stopTagScan()
                ble.onTagsRead = nil
            }
        }
    }
}
