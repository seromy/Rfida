import SwiftUI

/// 4大情景畫面共用嘅「掃描/停止掃描」按鈕。冇固定掃描時長:
/// 讀卡器連續一段時間(設定內嘅秒數)讀唔到標籤就會自己停止,按鈕跟讀卡器回報嘅狀態更新。
/// 呢度刻意唔顯示倒數,因為BLE延遲會令手機倒數同讀卡器實際計時唔一致。
struct TagScanControlButton: View {
    @EnvironmentObject var ble: BLEManager
    let mode: ScanMode

    var body: some View {
        let reader = ble.reader
        Section {
            Button {
                if reader.canStop {
                    ble.stopTagScan(userInitiated: true)
                } else {
                    ble.startTagScan(mode: mode)
                }
            } label: {
                HStack {
                    Label(buttonTitle(reader), systemImage: buttonIcon(reader))
                        .foregroundStyle(reader.canStop ? Color.red : Color.accentColor)
                    if isWaiting(reader) {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!(reader.canStop || (reader.canStart && ble.isConnected)))

            ForEach(Array(statusLines(reader).enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.color)
            }

            if showsReadSettings(reader) {
                Button("讀取設定") { ble.readReaderSettings() }
                    .disabled(!reader.canReadSettings)
            }
        }
    }

    private func buttonTitle(_ reader: ReaderSnapshot) -> String {
        switch reader.phase {
        case .idle: return "掃描"
        case .starting, .scanning, .unconfirmed: return "停止掃描"
        case .stopping: return "正在停止…"
        }
    }

    private func buttonIcon(_ reader: ReaderSnapshot) -> String {
        switch reader.phase {
        case .idle: return "play.circle.fill"
        case .starting, .scanning, .unconfirmed: return "stop.circle.fill"
        case .stopping: return "hourglass"
        }
    }

    private func isWaiting(_ reader: ReaderSnapshot) -> Bool {
        switch reader.phase {
        case .starting, .stopping: return true
        case .idle, .scanning, .unconfirmed: return reader.startBlocker == .settingsInProgress
        }
    }

    private func showsReadSettings(_ reader: ReaderSnapshot) -> Bool {
        guard !reader.isDemo, reader.isLinkReady else { return false }
        return reader.startBlocker == .settingsUnconfirmed || reader.phase == .unconfirmed(.fault)
    }

    private struct StatusLine {
        let text: String
        let color: Color
    }

    private func statusLines(_ reader: ReaderSnapshot) -> [StatusLine] {
        let idleSeconds = reader.confirmedSettings?.idleSeconds
        var lines: [StatusLine] = []
        switch reader.phase {
        case .idle:
            if let notice = reader.notice {
                lines.append(StatusLine(text: ReaderMessages.notice(notice, idleSeconds: idleSeconds),
                                        color: notice == .startNotConfirmed ? .orange : .secondary))
            }
            if let blocker = reader.startBlocker, let text = ReaderMessages.startBlocker(blocker, isConnected: ble.isConnected) {
                lines.append(StatusLine(text: text, color: blocker == .settingsUnconfirmed ? .orange : .secondary))
                if blocker == .settingsUnconfirmed, case .failed(let kind, let code)? = reader.settingsOutcome {
                    lines.append(StatusLine(text: ReaderMessages.settingsFailure(kind: kind, code: code), color: .red))
                }
            } else if reader.isDemo {
                lines.append(StatusLine(text: "示範模式：模擬掃描，不會控制真實讀卡器。", color: .secondary))
            }
        case .starting:
            lines.append(StatusLine(text: "正在啟動…（等待讀卡器確認開始掃描）", color: .secondary))
        case .scanning:
            if reader.isDemo {
                lines.append(StatusLine(text: "示範模式：模擬掃描中，請按「停止掃描」結束。", color: .secondary))
            } else {
                let limit = idleSeconds.map { "連續 \($0) 秒" } ?? "一段時間"
                lines.append(StatusLine(text: "掃描中。\(limit)沒有讀到標籤，讀卡器會自動停止。", color: .secondary))
                lines.append(StatusLine(text: ReaderMessages.idleResetHelp, color: .secondary))
                lines.append(StatusLine(text: "本次讀取 \(reader.scanReadCount) 次（包括重複）", color: .secondary))
            }
        case .stopping:
            lines.append(StatusLine(text: "正在等待讀卡器確認停止…", color: .secondary))
        case .unconfirmed(let issue):
            lines.append(StatusLine(text: ReaderMessages.issue(issue), color: .red))
        }
        return lines
    }
}
