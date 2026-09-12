import SwiftUI

/// 情景3:返office前清點(歸還) — 將「應有清單」同「而家掃到」自動比對,揪出缺件。
struct ReturnCheckView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore
    @StateObject private var viewModel = ReturnCheckViewModel()
    @State private var showCompletionTick = false

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
                    Button("讀取應有清單") {
                        Task { await viewModel.loadExpectedItems() }
                    }
                    .disabled(viewModel.selectedJobId == nil || viewModel.isLoadingExpected)
                }

                if !viewModel.expectedItems.isEmpty {
                    let diff = viewModel.diff

                    Section("核對結果") {
                        LabeledContent("應有", value: "\(viewModel.expectedItems.count)")
                        LabeledContent("已核對", value: "\(diff.matched.count)")
                        LabeledContent("缺件", value: "\(diff.missing.count)")
                            .foregroundStyle(diff.missing.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                    }

                    if !diff.missing.isEmpty {
                        Section("缺件清單") {
                            ForEach(diff.missing, id: \.epc) { item in
                                Label(masterData.equipmentByEPC[item.epc]?.name ?? item.epc, systemImage: "xmark.circle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if !diff.unexpected.isEmpty {
                        Section("額外掃到(非此Job)") {
                            ForEach(diff.unexpected, id: \.self) { epc in
                                Text(masterData.equipmentByEPC[epc]?.name ?? epc)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Section {
                        Button {
                            Task { await viewModel.submit() }
                        } label: {
                            if viewModel.isSubmitting { ProgressView() } else { Text("提交歸還紀錄") }
                        }
                        .disabled(viewModel.isSubmitting)
                    }
                }

                if let message = viewModel.lastMessage {
                    Text(message).foregroundStyle(.green)
                }
                if let error = viewModel.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("3. 返office前清點")
            .onAppear {
                ble.onTagsRead = { reads in viewModel.handle(reads: reads) }
                ble.send(mode: .batch)
            }
            .onDisappear {
                ble.send(mode: .idle)
                ble.onTagsRead = nil
            }
            .overlay {
                completionTickOverlay
            }
            .onChange(of: viewModel.justCompleted) { newValue in
                guard newValue else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    showCompletionTick = true
                }
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCompletionTick = false
                    }
                    viewModel.justCompleted = false
                }
            }
        }
    }

    /// 情景3掃齊晒(冇缺件)嗰下彈出嘅明顯剔號提示,配合特別完成音一齊出現。
    private var completionTickOverlay: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("全部器材已歸還")
                .font(.headline)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 16)
        .scaleEffect(showCompletionTick ? 1 : 0.4)
        .opacity(showCompletionTick ? 1 : 0)
        .allowsHitTesting(false)
    }
}
