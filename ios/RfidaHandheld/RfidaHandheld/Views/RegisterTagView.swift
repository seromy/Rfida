import SwiftUI

/// 情景1:錄入新標籤 — 將EPC同器材資料配對登記。
struct RegisterTagView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore
    @StateObject private var viewModel = RegisterTagViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section { ConnectionStatusBadge() }

                if viewModel.hasMultipleTags {
                    Section {
                        MultiTagWarningView(count: viewModel.detectedEPCs.count)
                    }
                }

                Section("偵測到嘅標籤") {
                    if viewModel.detectedEPCs.isEmpty {
                        Text("請將一件器材放近讀寫頭…").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.detectedEPCs, id: \.self) { epc in
                            Text(epc).font(.system(.body, design: .monospaced))
                        }
                    }
                    if !viewModel.detectedEPCs.isEmpty {
                        Button("清空重新偵測", role: .destructive) {
                            viewModel.clearDetected()
                        }
                    }
                }

                Section("器材資料") {
                    TextField("名稱(例:Sony A7IV 機身)", text: $viewModel.name)
                    TextField("分類(例:機身/鏡頭/腳架)", text: $viewModel.category)
                    TextField("序號(選填)", text: $viewModel.serialNumber)
                }
                .disabled(viewModel.singleDetectedEPC == nil)

                Section {
                    Button {
                        Task { await viewModel.submit(masterData: masterData) }
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("配對登記")
                        }
                    }
                    .disabled(viewModel.singleDetectedEPC == nil || viewModel.isSubmitting)
                }

                if let message = viewModel.lastMessage {
                    Text(message).foregroundStyle(.green)
                }
                if let error = viewModel.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("1. 錄入新標籤")
            .onAppear {
                viewModel.updateKnownEPCs(Set(masterData.equipment.map { $0.epc.uppercased() }))
                ble.onTagsRead = { reads in viewModel.handle(reads: reads) }
                ble.send(mode: .register)
            }
            .onDisappear {
                ble.send(mode: .idle)
                ble.onTagsRead = nil
            }
        }
    }
}
