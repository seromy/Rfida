import Foundation

/// App 所見嘅掃描階段。韌體先係「無讀取自動停止」嘅權威:App 唔會因為本地計時而發 IDLE,
/// 只會跟 `@STATE` 快照更新按鈕。
enum ScanPhase: Equatable {
    /// 冇掃描;是否可以開始見 `StartBlocker`。
    case idle
    /// 已發 MODE 指令,等待 SCANNING。期間嘅 READY 可能係 START 前嘅 STOP preflight,唔代表掃描完成。
    case starting
    /// 已見到 SCANNING。
    case scanning
    /// 等待 READY 確認已停止。
    case stopping(StopOrigin)
    /// 未能確認停止/狀態;停用「掃描」,但容許「停止掃描」同「讀取設定」復原。
    case unconfirmed(ScanIssue)
}

enum StopOrigin: Equatable {
    /// App 發出 IDLE(使用者按停止、離開畫面、App 入背景、中斷連接)。
    case app
    /// 韌體自己回報 STOPPING(通常係無讀取逾時)。
    case device
    /// 開始掃描逾時,App 盡力發出 IDLE。
    case startTimeout
}

enum ScanIssue: Equatable {
    case stopUnconfirmed
    case stateReportsLost
    case fault
    case commandWriteFailed
}

/// 回到待命後畀使用者睇嘅一次性提示。
enum ScanNotice: Equatable {
    /// 讀卡器自行停止(通常係連續 N 秒冇讀到標籤)。
    case autoStopped
    /// 未見到 SCANNING 就已經回到 READY,唔可以當成掃描成功。
    case startNotConfirmed
    /// 之前未確認,而家已確認讀卡器回到 READY。
    case recovered
}

enum StartBlocker: Equatable {
    case linkNotReady
    case scanActive
    case settingsInProgress
    case settingsUnconfirmed
    case noStateReport
    case readerNotReady(ReaderState)
}

enum SettingsKind: Equatable {
    case get
    case set
}

enum SettingsOutcome: Equatable {
    case succeeded(SettingsKind)
    /// `code` 係韌體錯誤碼(例如 BUSY)或者 App 端代碼(NO_REPLY_TIMEOUT、ECHO_MISMATCH、INVALID_VALUES、WRITE_FAILED)。
    case failed(SettingsKind, code: String)
}

enum ReaderEffect {
    case send(ReaderCommand)
    /// 已通過控制行分流嘅有效 EPC(未做任何業務層去重)。
    case tags([TagRead])
}

/// 畀 SwiftUI 顯示用嘅快照;只喺內容有變時先發布。
struct ReaderSnapshot: Equatable {
    var isDemo = false
    var isLinkReady = false
    var readerState: ReaderState?
    var isStateFresh = false
    var phase: ScanPhase = .idle
    var notice: ScanNotice?
    var startBlocker: StartBlocker? = .linkNotReady
    var canStop = false
    var confirmedSettings: ReaderSettings?
    var settingsActivity: SettingsKind?
    var requestedSettings: ReaderSettings?
    var settingsOutcome: SettingsOutcome?
    var canReadSettings = false
    var canApplySettings = false
    /// 今次掃描收到嘅有效 EPC 次數(包括重複同已登記標籤)。
    var scanReadCount = 0

    var canStart: Bool { startBlocker == nil }

    static func demo(isConnected: Bool, isScanning: Bool) -> ReaderSnapshot {
        var snapshot = ReaderSnapshot()
        snapshot.isDemo = true
        snapshot.isLinkReady = isConnected
        snapshot.phase = isScanning ? .scanning : .idle
        snapshot.startBlocker = !isConnected ? .linkNotReady : (isScanning ? .scanActive : nil)
        snapshot.canStop = isScanning
        return snapshot
    }
}

/// 一條 BLE 連接(session)入面嘅讀卡器掃描同設定狀態機。
/// 純邏輯、冇 CoreBluetooth、冇 Timer:時間由呼叫方傳入(monotonic 秒數),所以可以決定性咁測試。
/// `BLEManager` 負責將回傳嘅 `ReaderEffect` 寫去 BLE / 交畀畫面。
struct ReaderSessionModel {
    struct Timing {
        var settingsTimeout: TimeInterval = 8
        var startTimeout: TimeInterval = 5
        var stopTimeout: TimeInterval = 6
        /// 掃描進行中超過呢個時間收唔到 @STATE,就當狀態未確認。
        var stateReportTimeout: TimeInterval = 3
        /// 未有證據顯示韌體已處理 MODE 時,IDLE 發出後要等咁耐先接受 READY,
        /// 以免將 IDLE 之前已經喺路上嘅舊 READY 誤當成停止確認。
        var readyTrustDelay: TimeInterval = 1
        var startupBusyRetryDelay: TimeInterval = 1
        var startupBusyRetryLimit = 3
        /// 撳「掃描」之後咁短時間內再撳,當誤觸雙擊,唔發 IDLE。
        var stopTapGuard: TimeInterval = 0.4
    }

    struct SettingsOperation: Equatable {
        let kind: SettingsKind
        let id: Int
        let session: Int
        let requested: ReaderSettings?
        let deadline: TimeInterval
        let automatic: Bool
    }

    let timing: Timing

    private(set) var session: Int?
    private(set) var readerState: ReaderState?
    private(set) var lastStateAt: TimeInterval?
    private(set) var phase: ScanPhase = .idle
    private(set) var notice: ScanNotice?
    private(set) var confirmedSettings: ReaderSettings?
    private(set) var settingsOperation: SettingsOperation?
    private(set) var settingsOutcome: SettingsOutcome?
    private(set) var scanReadCount = 0
    /// 最近一次收到有效 EPC 嘅時間(喺業務層去重之前更新,重複標籤都計)。只作顯示/診斷,唔會觸發 IDLE。
    private(set) var lastTagActivityAt: TimeInterval?

    /// 跨 session 遞增,令舊連接嘅回覆唔會撞中新請求。
    private var nextRequestID = ReaderSettingsLimits.requestIDs.lowerBound
    private var lineBuffer = NUSLineBuffer()
    private var startupRetriesUsed = 0
    private var startupRetryAt: TimeInterval?
    private var phaseEnteredAt: TimeInterval = 0
    private var phaseDeadline: TimeInterval?
    private var startSentAt: TimeInterval?
    private var lastStopSentAt: TimeInterval?
    /// 發出 MODE 之後,有冇見過韌體已處理佢嘅證據(非 READY 快照或者 EPC)。
    private var firmwareProgressSinceStart = true

    init(timing: Timing = Timing()) {
        self.timing = timing
    }

    // MARK: - 連接生命週期

    /// RX 已找到而且 TX 訂閱已確認:開始新 session,並讀取(GET)設定。永遠唔會自動 SET。
    mutating func linkReady(session newSession: Int, now: TimeInterval) -> [ReaderEffect] {
        resetSession()
        session = newSession
        phaseEnteredAt = now
        return beginSettings(.get, requested: nil, automatic: true, now: now)
    }

    /// 斷線、藍牙不可用、換裝置或者訂閱失效:清走所有 session 狀態。之後唔會自動恢復掃描。
    mutating func linkLost() {
        resetSession()
    }

    // MARK: - 收資料

    mutating func receive(_ data: Data, session incoming: Int, now: TimeInterval) -> [ReaderEffect] {
        guard let session, incoming == session else { return [] }
        var effects: [ReaderEffect] = []
        var tags: [TagRead] = []
        func flushTags() {
            if !tags.isEmpty { effects.append(.tags(tags)); tags.removeAll() }
        }
        for line in lineBuffer.feed(data) {
            switch NUSLine.classify(line) {
            case .settings(let reply):
                flushTags()
                handleSettingsReply(reply, now: now)
            case .state(let state):
                flushTags()
                handleState(state, now: now)
            case .tag(let epc, let rssi):
                if let read = acceptTag(epc: epc, rssi: rssi, now: now) { tags.append(read) }
            case .ignored:
                break
            }
        }
        flushTags()
        return effects
    }

    mutating func tick(now: TimeInterval) -> [ReaderEffect] {
        guard session != nil else { return [] }
        var effects: [ReaderEffect] = []

        if let operation = settingsOperation, now >= operation.deadline {
            // 冇回覆唔等於冇寫入:只標示未確認,唔會自動重發或者還原。
            failSettings(code: "NO_REPLY_TIMEOUT")
        }
        if let retryAt = startupRetryAt, now >= retryAt {
            startupRetryAt = nil
            effects += beginSettings(.get, requested: nil, automatic: true, now: now)
        }

        switch phase {
        case .starting, .scanning, .stopping:
            let lastHeard = max(lastStateAt ?? phaseEnteredAt, phaseEnteredAt)
            if now - lastHeard >= timing.stateReportTimeout {
                let stopAlreadySent: Bool
                if case .stopping(let origin) = phase { stopAlreadySent = origin != .device } else { stopAlreadySent = false }
                enter(.unconfirmed(.stateReportsLost), now: now)
                if !stopAlreadySent { effects += sendStop(now: now) }
                return effects
            }
        case .idle, .unconfirmed:
            break
        }

        if let deadline = phaseDeadline, now >= deadline {
            switch phase {
            case .starting:
                enter(.stopping(.startTimeout), now: now)
                phaseDeadline = now + timing.stopTimeout
                effects += sendStop(now: now)
            case .stopping(let origin):
                enter(.unconfirmed(.stopUnconfirmed), now: now)
                if origin == .device { effects += sendStop(now: now) }
            case .idle, .scanning, .unconfirmed:
                break
            }
        }
        return effects
    }

    // MARK: - 使用者操作

    mutating func startScan(mode: ScanMode, now: TimeInterval) -> [ReaderEffect] {
        guard mode != .idle, startBlocker(now: now) == nil else { return [] }
        enter(.starting, now: now)
        phaseDeadline = now + timing.startTimeout
        notice = nil
        scanReadCount = 0
        lastTagActivityAt = nil
        startSentAt = now
        lastStopSentAt = nil
        firmwareProgressSinceStart = false
        return [.send(.mode(mode))]
    }

    /// 每個停止意圖只發一次 IDLE;已經喺 stopping 就唔再發。
    mutating func stopScan(userInitiated: Bool, now: TimeInterval) -> [ReaderEffect] {
        switch phase {
        case .starting:
            if userInitiated, let sentAt = startSentAt, now - sentAt < timing.stopTapGuard { return [] }
        case .scanning, .unconfirmed:
            break
        case .idle, .stopping:
            return []
        }
        enter(.stopping(.app), now: now)
        phaseDeadline = now + timing.stopTimeout
        return sendStop(now: now)
    }

    mutating func readSettings(now: TimeInterval) -> [ReaderEffect] {
        guard canReadSettings else { return [] }
        startupRetryAt = nil
        return beginSettings(.get, requested: nil, automatic: false, now: now)
    }

    mutating func applySettings(_ settings: ReaderSettings, now: TimeInterval) -> [ReaderEffect] {
        guard canApplySettings(now: now),
              ReaderSettingsLimits.editablePower.contains(settings.power),
              ReaderSettingsLimits.idleSeconds.contains(settings.idleSeconds) else { return [] }
        return beginSettings(.set, requested: settings, automatic: false, now: now)
    }

    /// Write-with-response 回報錯誤。
    mutating func writeFailed(_ command: ReaderCommand, session incoming: Int, now: TimeInterval) -> [ReaderEffect] {
        guard let session, incoming == session else { return [] }
        switch command {
        case .getSettings(let id), .setSettings(let id, _):
            if settingsOperation?.id == id { failSettings(code: "WRITE_FAILED") }
            return []
        case .mode(.idle):
            switch phase {
            case .stopping, .unconfirmed: enter(.unconfirmed(.commandWriteFailed), now: now)
            case .idle, .starting, .scanning: break
            }
            return []
        case .mode:
            guard phase == .starting else { return [] }
            enter(.unconfirmed(.commandWriteFailed), now: now)
            return sendStop(now: now)
        }
    }

    // MARK: - 查詢

    var canStop: Bool {
        switch phase {
        case .starting, .scanning, .unconfirmed: return true
        case .idle, .stopping: return false
        }
    }

    var canReadSettings: Bool {
        guard session != nil, settingsOperation == nil else { return false }
        switch phase {
        case .idle, .unconfirmed: return true
        case .starting, .scanning, .stopping: return false
        }
    }

    func canApplySettings(now: TimeInterval) -> Bool {
        session != nil && settingsOperation == nil && startupRetryAt == nil && phase == .idle
            && readerState == .ready && isStateFresh(now: now)
    }

    func isStateFresh(now: TimeInterval) -> Bool {
        guard let lastStateAt else { return false }
        return now - lastStateAt < timing.stateReportTimeout
    }

    func startBlocker(now: TimeInterval) -> StartBlocker? {
        guard session != nil else { return .linkNotReady }
        guard phase == .idle else { return .scanActive }
        if settingsOperation != nil || startupRetryAt != nil { return .settingsInProgress }
        guard confirmedSettings != nil else { return .settingsUnconfirmed }
        guard let readerState, isStateFresh(now: now) else { return .noStateReport }
        guard readerState == .ready else { return .readerNotReady(readerState) }
        return nil
    }

    func snapshot(now: TimeInterval) -> ReaderSnapshot {
        var snapshot = ReaderSnapshot()
        snapshot.isLinkReady = session != nil
        snapshot.readerState = readerState
        snapshot.isStateFresh = isStateFresh(now: now)
        snapshot.phase = phase
        snapshot.notice = notice
        snapshot.startBlocker = startBlocker(now: now)
        snapshot.canStop = canStop
        snapshot.confirmedSettings = confirmedSettings
        snapshot.settingsActivity = settingsOperation?.kind ?? (startupRetryAt != nil ? .get : nil)
        snapshot.requestedSettings = settingsOperation?.requested
        snapshot.settingsOutcome = settingsOutcome
        snapshot.canReadSettings = canReadSettings
        snapshot.canApplySettings = canApplySettings(now: now)
        snapshot.scanReadCount = scanReadCount
        return snapshot
    }

    // MARK: - 內部

    private mutating func resetSession() {
        session = nil
        readerState = nil
        lastStateAt = nil
        phase = .idle
        notice = nil
        confirmedSettings = nil
        settingsOperation = nil
        settingsOutcome = nil
        scanReadCount = 0
        lastTagActivityAt = nil
        lineBuffer.reset()
        startupRetriesUsed = 0
        startupRetryAt = nil
        phaseDeadline = nil
        startSentAt = nil
        lastStopSentAt = nil
        firmwareProgressSinceStart = true
    }

    private mutating func enter(_ newPhase: ScanPhase, now: TimeInterval) {
        phase = newPhase
        phaseEnteredAt = now
        phaseDeadline = nil
    }

    private mutating func sendStop(now: TimeInterval) -> [ReaderEffect] {
        lastStopSentAt = now
        return [.send(.mode(.idle))]
    }

    private mutating func acceptTag(epc: String, rssi: Int?, now: TimeInterval) -> TagRead? {
        // 韌體只會喺 SCANNING 時轉發 EPC;待命時收到嘅只可能係過時資料。
        guard phase != .idle else { return nil }
        lastTagActivityAt = now
        scanReadCount += 1
        firmwareProgressSinceStart = true
        return TagRead(epc: epc, rssi: rssi, timestamp: Date())
    }

    private mutating func handleState(_ state: ReaderState, now: TimeInterval) {
        readerState = state
        lastStateAt = now
        if state != .ready { firmwareProgressSinceStart = true }

        switch state {
        case .fault:
            if phase != .unconfirmed(.fault) {
                enter(.unconfirmed(.fault), now: now)
                notice = nil
            }
        case .scanning:
            switch phase {
            case .idle, .starting:
                enter(.scanning, now: now)
                notice = nil
            case .scanning, .stopping, .unconfirmed:
                break
            }
        case .stopping:
            if phase == .scanning {
                enter(.stopping(.device), now: now)
                phaseDeadline = now + timing.stopTimeout
                lastStopSentAt = nil
            }
        case .ready:
            guard readyConfirmsStopped(now: now) else { return }
            switch phase {
            case .idle:
                break
            case .starting:
                // 韌體已處理 MODE,但未見 SCANNING 就返 READY:唔可以報掃描成功。
                enter(.idle, now: now)
                notice = scanReadCount > 0 ? .autoStopped : .startNotConfirmed
            case .scanning:
                enter(.idle, now: now)
                notice = .autoStopped
            case .stopping(let origin):
                enter(.idle, now: now)
                switch origin {
                case .app: notice = nil
                case .device: notice = .autoStopped
                case .startTimeout: notice = scanReadCount > 0 ? nil : .startNotConfirmed
                }
            case .unconfirmed:
                enter(.idle, now: now)
                notice = .recovered
            }
        case .starting, .configuring, .unknown:
            break
        }
    }

    private func readyConfirmsStopped(now: TimeInterval) -> Bool {
        if firmwareProgressSinceStart { return true }
        if let lastStopSentAt, now - lastStopSentAt >= timing.readyTrustDelay { return true }
        return false
    }

    private mutating func beginSettings(_ kind: SettingsKind, requested: ReaderSettings?, automatic: Bool, now: TimeInterval) -> [ReaderEffect] {
        guard let session, settingsOperation == nil else { return [] }
        let command: ReaderCommand
        let id = nextRequestID
        switch (kind, requested) {
        case (.get, _):
            command = .getSettings(id: id)
        case (.set, let settings?):
            command = .setSettings(id: id, settings: settings)
        case (.set, nil):
            return []
        }
        nextRequestID = id >= ReaderSettingsLimits.requestIDs.upperBound ? ReaderSettingsLimits.requestIDs.lowerBound : id + 1
        settingsOperation = SettingsOperation(kind: kind, id: id, session: session, requested: requested,
                                              deadline: now + timing.settingsTimeout, automatic: automatic)
        settingsOutcome = nil
        return [.send(command)]
    }

    private mutating func handleSettingsReply(_ reply: SettingsReply, now: TimeInterval) {
        // ID 同 session 都要對得上;其他(過時/重複/未請求)回覆一律丟棄。
        guard let operation = settingsOperation, operation.id == reply.id, operation.session == session else { return }
        switch reply {
        case .ok(_, let values):
            switch operation.kind {
            case .get:
                guard ReaderSettingsLimits.reportedPower.contains(values.power),
                      ReaderSettingsLimits.idleSeconds.contains(values.idleSeconds) else {
                    failSettings(code: "INVALID_VALUES")
                    return
                }
            case .set:
                guard values == operation.requested else {
                    failSettings(code: "ECHO_MISMATCH")
                    return
                }
            }
            settingsOperation = nil
            confirmedSettings = values
            settingsOutcome = .succeeded(operation.kind)
        case .error(_, let reason):
            if operation.automatic, reason == "BUSY", startupRetriesUsed < timing.startupBusyRetryLimit {
                startupRetriesUsed += 1
                settingsOperation = nil
                startupRetryAt = now + timing.startupBusyRetryDelay
                return
            }
            failSettings(code: reason)
        }
    }

    private mutating func failSettings(code: String) {
        guard let operation = settingsOperation else { return }
        settingsOperation = nil
        // SET 失敗或逾時:讀卡器/ESP32 可能已部分寫入,已確認數值作廢,要靠 GET 重新核對。
        if operation.kind == .set { confirmedSettings = nil }
        settingsOutcome = .failed(operation.kind, code: code)
    }
}
