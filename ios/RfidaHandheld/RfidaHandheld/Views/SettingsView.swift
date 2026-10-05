import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.backendBaseURL) private var backendBaseURL: String = ""
    @AppStorage(SettingsKey.scanSoundMuted) private var scanSoundMuted: Bool = false
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var masterData: MasterDataStore

    /// 讀卡器設定草稿(只存喺畫面,唔會自動發送)。
    @State private var draftPowerText = "\(ReaderSettingsLimits.defaultPower)"
    @State private var draftSecondsText = "\(ReaderSettingsLimits.defaultIdleSeconds)"
    @State private var draftsEdited = false

    var body: some View {
        Form {
            Section("示範模式") {
                Toggle("示範模式(Demo Mode)", isOn: $ble.isDemoMode)
                Text("開啟後,App會自動連接一個模擬嘅示範手提機,並用內置嘅假器材/公司/Job資料,唔需要真實RFID硬件或後台伺服器,方便展示四大使用情景。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            readerSettingsSection

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
            }
        }
        .navigationTitle("設定")
        .scrollDismissesKeyboard(.interactively)
        .onAppear { prefillDraftsIfNeeded() }
        .onChange(of: ble.reader.confirmedSettings) { _ in prefillDraftsIfNeeded() }
        .onChange(of: ble.isDemoMode) { _ in
            Task { await masterData.refreshAll() }
        }
    }

    // MARK: - 讀卡器設定

    private var readerSettingsSection: some View {
        let reader = ble.reader
        let controlsDisabled = reader.isDemo
        return Section {
            if reader.isDemo {
                Text("示範模式不會連接真實讀卡器，讀卡器設定已停用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("讀卡器目前功率等級", value: reader.confirmedSettings.map { "\($0.power)" } ?? "未確認")
            LabeledContent("讀卡器目前自動停止", value: reader.confirmedSettings.map { "\($0.idleSeconds) 秒" } ?? "未確認")
            if let power = reader.confirmedSettings?.power, !ReaderSettingsLimits.editablePower.contains(power) {
                Text("目前功率 \(power) 超出可編輯範圍（10–26）。按「套用設定」會改為下面的草稿數值。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            integerRow(title: "功率等級", text: $draftPowerText, range: ReaderSettingsLimits.editablePower,
                       fallback: ReaderSettingsLimits.defaultPower, unit: nil)
                .disabled(controlsDisabled)
            integerRow(title: "無讀取自動停止", text: $draftSecondsText, range: ReaderSettingsLimits.idleSeconds,
                       fallback: ReaderSettingsLimits.defaultIdleSeconds, unit: "秒")
                .disabled(controlsDisabled)

            Text(ReaderMessages.idleResetHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("功率等級是讀卡器的原始數值，並非實測 dBm。所有掃描畫面（錄入標籤及批量掃描）都使用同一設定。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = draftError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let draft = parsedDraft, !controlsDisabled {
                Text(applySummary(draft, confirmed: reader.confirmedSettings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("讀取設定") { ble.readReaderSettings() }
                .disabled(controlsDisabled || !reader.canReadSettings)

            Button("套用設定") {
                if let draft = parsedDraft { ble.applyReaderSettings(draft) }
            }
            .disabled(controlsDisabled || !reader.canApplySettings || parsedDraft == nil)

            if !controlsDisabled {
                settingsStatus(reader)
            }
        } header: {
            Text("讀卡器設定")
        }
    }

    @ViewBuilder
    private func settingsStatus(_ reader: ReaderSnapshot) -> some View {
        if !reader.isLinkReady {
            Text("未連接手提機。請先在首頁連接 RFID-01。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let activity = reader.settingsActivity {
            HStack {
                ProgressView()
                Text(activity == .get ? "正在讀取設定…" : "正在套用設定，等待讀卡器確認…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch reader.settingsOutcome {
            case .succeeded(let kind)?:
                Text(ReaderMessages.settingsSuccess(kind)).font(.caption).foregroundStyle(.green)
            case .failed(let kind, let code)?:
                Text(ReaderMessages.settingsFailure(kind: kind, code: code)).font(.caption).foregroundStyle(.red)
            case nil:
                EmptyView()
            }
            if reader.phase != .idle {
                Text("掃描進行中或未確認停止，請先停止掃描再套用設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !reader.canApplySettings, reader.readerState != .ready || !reader.isStateFresh {
                Text("讀卡器未回報待命（READY），暫時不能套用設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func integerRow(title: String, text: Binding<String>, range: ClosedRange<Int>, fallback: Int, unit: String?) -> some View {
        let stepperValue = Binding<Int>(
            get: { Self.strictInteger(text.wrappedValue).map { min(max($0, range.lowerBound), range.upperBound) } ?? fallback },
            set: { newValue in
                text.wrappedValue = "\(newValue)"
                draftsEdited = true
            }
        )
        return HStack {
            Text(title)
            Spacer()
            TextField("", text: Binding(
                get: { text.wrappedValue },
                set: { newValue in
                    text.wrappedValue = newValue
                    draftsEdited = true
                }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            if let unit { Text(unit).foregroundStyle(.secondary) }
            Stepper(title, value: stepperValue, in: range)
                .labelsHidden()
        }
    }

    private var parsedDraft: ReaderSettings? {
        guard let power = Self.strictInteger(draftPowerText), ReaderSettingsLimits.editablePower.contains(power),
              let seconds = Self.strictInteger(draftSecondsText), ReaderSettingsLimits.idleSeconds.contains(seconds) else { return nil }
        return ReaderSettings(power: power, idleSeconds: seconds)
    }

    private var draftError: String? {
        var errors: [String] = []
        if !(Self.strictInteger(draftPowerText).map(ReaderSettingsLimits.editablePower.contains) ?? false) {
            errors.append("功率等級請輸入 10–26 的整數。")
        }
        if !(Self.strictInteger(draftSecondsText).map(ReaderSettingsLimits.idleSeconds.contains) ?? false) {
            errors.append("自動停止秒數請輸入 1–60 的整數。")
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func applySummary(_ draft: ReaderSettings, confirmed: ReaderSettings?) -> String {
        var text = "按「套用設定」會設定：功率等級 \(draft.power)、無讀取自動停止 \(draft.idleSeconds) 秒。"
        if let confirmed, confirmed.power != draft.power {
            text += "\n注意：功率會由 \(confirmed.power) 改為 \(draft.power)。"
        }
        return text
    }

    /// 草稿未被改動過時,用讀卡器已確認數值做起點(功率超出可編輯範圍就保留預設草稿)。唔會自動發送。
    private func prefillDraftsIfNeeded() {
        guard !draftsEdited, let confirmed = ble.reader.confirmedSettings else { return }
        if ReaderSettingsLimits.editablePower.contains(confirmed.power) {
            draftPowerText = "\(confirmed.power)"
        }
        draftSecondsText = "\(confirmed.idleSeconds)"
    }

    private static func strictInteger(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 3, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }
}
