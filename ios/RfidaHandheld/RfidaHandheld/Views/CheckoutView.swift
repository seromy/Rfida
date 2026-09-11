import SwiftUI

/// 情景2:出發前登記(出Job) — 盡量一次過讀盡成批器材,記錄呢次帶走嘅清單。
struct CheckoutView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore
    @StateObject private var viewModel = CheckoutViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section { ConnectionStatusBadge() }

                Section("選擇") {
                    Picker("員工", selection: $viewModel.selectedStaffId) {
                        Text("請選擇").tag(Int?.none)
                        ForEach(masterData.staff) { staff in
                            Text(staff.name).tag(Optional(staff.id))
                        }
                    }
                    Picker("Job", selection: $viewModel.selectedJobId) {
                        Text("請選擇").tag(Int?.none)
                        ForEach(masterData.openJobs) { job in
                            Text(job.name).tag(Optional(job.id))
                        }
                    }
                }

                Section("已掃描器材(\(viewModel.scannedEPCs.count))") {
                    if viewModel.scannedEPCs.isEmpty {
                        Text("開始批量掃描帶走嘅器材…").foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.scannedEPCs, id: \.self) { epc in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(masterData.equipmentByEPC[epc]?.name ?? "未知器材")
                                    Text(epc).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if masterData.equipmentByEPC[epc] == nil {
                                    Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                                }
                            }
                            .swipeActions {
                                Button("移除", role: .destructive) { viewModel.remove(epc: epc) }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.submit(masterData: masterData) }
                    } label: {
                        if viewModel.isSubmitting { ProgressView() } else { Text("提交出Job紀錄") }
                    }
                    .disabled(viewModel.isSubmitting || viewModel.scannedEPCs.isEmpty)

                    Button("清空重新掃描", role: .destructive) { viewModel.reset() }
                }

                if let message = viewModel.lastMessage {
                    Text(message).foregroundStyle(.green)
                }
                if let error = viewModel.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("2. 出發前登記")
            .onAppear {
                ble.onTagsRead = { reads in viewModel.handle(reads: reads) }
                ble.send(mode: .batch)
            }
            .onDisappear {
                ble.send(mode: .idle)
                ble.onTagsRead = nil
            }
        }
    }
}
