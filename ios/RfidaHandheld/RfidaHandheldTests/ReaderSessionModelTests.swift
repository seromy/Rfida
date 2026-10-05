import XCTest
@testable import RfidaHandheld

/// 以決定性時間驅動 `ReaderSessionModel`,記錄佢發出嘅指令同交畀畫面嘅 EPC。
private final class ReaderHarness {
    var model = ReaderSessionModel()
    var now: TimeInterval = 1_000
    var session = 7
    private(set) var sent: [ReaderCommand] = []
    private(set) var delivered: [String] = []

    static let epc = "E280689420005015E1A661E8"

    var idleCount: Int { sent.filter { $0 == .mode(.idle) }.count }
    var startCount: Int { sent.filter { $0 == .mode(.batch) || $0 == .mode(.register) }.count }
    var pendingID: Int? { model.settingsOperation?.id }
    var snapshot: ReaderSnapshot { model.snapshot(now: now) }

    func record(_ effects: [ReaderEffect]) {
        for effect in effects {
            switch effect {
            case .send(let command): sent.append(command)
            case .tags(let reads): delivered += reads.map(\.epc)
            }
        }
    }

    func connect(session: Int = 7) {
        self.session = session
        record(model.linkReady(session: session, now: now))
    }

    func feed(_ text: String, session: Int? = nil) {
        record(model.receive(Data(text.utf8), session: session ?? self.session, now: now))
    }

    func state(_ name: String) { feed("\n@STATE:\(name)\n") }
    func reply(_ body: String, id: Int? = nil) { feed("\n@CFG2:\(id ?? pendingID ?? -1):\(body)\n") }
    func tick() { record(model.tick(now: now)) }

    /// 以 0.25 秒一步推前時間;`reporting` 非 nil 時每 0.5 秒送一次該狀態快照(先送快照再 tick)。
    func advance(_ seconds: TimeInterval, reporting stateName: String? = nil) {
        let end = now + seconds
        var nextReport = now + 0.5
        while now < end {
            now = min(now + 0.25, end)
            if let stateName, now >= nextReport {
                state(stateName)
                nextReport += 0.5
            }
            tick()
        }
    }

    func start(_ mode: ScanMode = .batch) { record(model.startScan(mode: mode, now: now)) }
    func stop(user: Bool = true) { record(model.stopScan(userInitiated: user, now: now)) }
    func read() { record(model.readSettings(now: now)) }
    func apply(_ power: Int, _ seconds: Int) { record(model.applySettings(ReaderSettings(power: power, idleSeconds: seconds), now: now)) }

    /// 連接 → GET OK → READY:可以開始掃描。
    func connectReadyToScan(settings: String = "20:10") {
        connect()
        reply("OK:\(settings)")
        state("READY")
    }

    func startScanning(_ mode: ScanMode = .batch) {
        connectReadyToScan()
        start(mode)
        advance(0.5)
        state("SCANNING")
    }
}

final class ReaderSettingsTests: XCTestCase {
    private let defaults = ReaderSettings(power: 20, idleSeconds: 10)

    func testReadyConnectionSendsGetOnlyAndNeverAutoSets() {
        let h = ReaderHarness()
        h.connect()
        XCTAssertEqual(h.sent, [.getSettings(id: 1)])
        h.advance(30, reporting: "READY")
        XCTAssertEqual(h.sent, [.getSettings(id: 1)])
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "NO_REPLY_TIMEOUT"))
        XCTAssertNil(h.model.confirmedSettings)
    }

    func testGetConfirmsDeviceValuesIncludingPower33() {
        let h = ReaderHarness()
        h.connect()
        h.reply("OK:33:10")
        XCTAssertEqual(h.model.confirmedSettings, ReaderSettings(power: 33, idleSeconds: 10))
        XCTAssertEqual(h.model.settingsOutcome, .succeeded(.get))
        XCTAssertNil(h.model.settingsOperation)
    }

    func testGetRejectsOutOfRangeReportedValues() {
        for body in ["OK:34:10", "OK:20:0", "OK:20:61"] {
            let h = ReaderHarness()
            h.connect()
            h.reply(body)
            XCTAssertNil(h.model.confirmedSettings, body)
            XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "INVALID_VALUES"), body)
        }
    }

    func testWrongRequestIDIsDiscarded() {
        let h = ReaderHarness()
        h.connect()
        h.reply("OK:20:10", id: 2)
        XCTAssertEqual(h.pendingID, 1)
        XCTAssertNil(h.model.confirmedSettings)
        XCTAssertNil(h.model.settingsOutcome)
        h.reply("OK:20:10", id: 1)
        XCTAssertEqual(h.model.confirmedSettings, defaults)
    }

    func testStaleSessionRepliesAreDiscarded() {
        let h = ReaderHarness()
        h.connect(session: 7)
        h.model.linkLost()
        h.connect(session: 8)
        XCTAssertEqual(h.sent.last, .getSettings(id: 2))

        h.reply("OK:20:10", id: 1)                          // 舊 ID
        h.feed("\n@CFG2:2:OK:20:10\n", session: 7)          // 啱 ID,舊 session
        XCTAssertNil(h.model.confirmedSettings)
        XCTAssertEqual(h.pendingID, 2)

        h.reply("OK:20:10", id: 2)
        XCTAssertEqual(h.model.confirmedSettings, defaults)
    }

    func testStateSnapshotIsNotASettingsResponse() {
        let h = ReaderHarness()
        h.connect()
        h.state("READY")
        XCTAssertEqual(h.pendingID, 1)
        XCTAssertNil(h.model.settingsOutcome)
    }

    func testSetSucceedsOnlyOnMatchingDeviceOK() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.apply(20, 5)
        XCTAssertEqual(h.sent.last, .setSettings(id: 2, settings: ReaderSettings(power: 20, idleSeconds: 5)))
        // 寫出咗唔等於成功
        XCTAssertNil(h.model.settingsOutcome)
        XCTAssertEqual(h.snapshot.settingsActivity, .set)
        XCTAssertEqual(h.snapshot.startBlocker, .settingsInProgress)

        h.reply("OK:20:5")
        XCTAssertEqual(h.model.confirmedSettings, ReaderSettings(power: 20, idleSeconds: 5))
        XCTAssertEqual(h.model.settingsOutcome, .succeeded(.set))
    }

    func testSetTimeoutLeavesValuesUnconfirmedWithoutResend() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.apply(20, 5)
        let id = h.pendingID
        let count = h.sent.count
        h.advance(8, reporting: "READY")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.set, code: "NO_REPLY_TIMEOUT"))
        XCTAssertNil(h.model.confirmedSettings)
        h.advance(60, reporting: "READY")
        XCTAssertEqual(h.sent.count, count)

        h.reply("OK:20:5", id: id)   // 遲到嘅回覆唔會變成成功
        XCTAssertNil(h.model.confirmedSettings)
        XCTAssertEqual(h.snapshot.startBlocker, .settingsUnconfirmed)
    }

    func testSetEchoMismatchIsNotSuccess() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.apply(20, 5)
        h.reply("OK:20:10")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.set, code: "ECHO_MISMATCH"))
        XCTAssertNil(h.model.confirmedSettings)
    }

    func testSetErrorIsNotRetriedAndGetRecovers() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.apply(22, 10)
        h.reply("ERR:READBACK_MISMATCH")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.set, code: "READBACK_MISMATCH"))
        XCTAssertNil(h.model.confirmedSettings)

        let count = h.sent.count
        h.advance(30, reporting: "READY")
        XCTAssertEqual(h.sent.count, count, "SET must never be retried automatically")

        XCTAssertTrue(h.model.canReadSettings)
        h.read()
        XCTAssertEqual(h.sent.last, .getSettings(id: 3))
        h.reply("OK:20:10")
        XCTAssertEqual(h.model.confirmedSettings, defaults)
        XCTAssertNil(h.snapshot.startBlocker)
    }

    func testOnlyOneOutstandingSettingsOperation() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.read()
        h.read()
        h.apply(20, 5)
        XCTAssertEqual(h.sent.filter { if case .getSettings = $0 { return true }; if case .setSettings = $0 { return true }; return false }.count, 2)
    }

    func testStartupBusyRetryIsBounded() {
        let h = ReaderHarness()
        h.connect()
        for attempt in 1...3 {
            h.reply("ERR:BUSY")
            XCTAssertNil(h.pendingID)
            XCTAssertEqual(h.snapshot.settingsActivity, .get)
            h.advance(1)
            XCTAssertEqual(h.sent.last, .getSettings(id: attempt + 1))
        }
        h.reply("ERR:BUSY")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "BUSY"))
        h.advance(10)
        XCTAssertEqual(h.sent.count, 4)
    }

    func testManualGetBusyIsNotRetried() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.read()
        h.reply("ERR:BUSY")
        let count = h.sent.count
        h.advance(10, reporting: "READY")
        XCTAssertEqual(h.sent.count, count)
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "BUSY"))
    }

    func testWriteFailureFailsSettingsAndStaleSessionIsIgnored() {
        let h = ReaderHarness()
        h.connect()
        h.record(h.model.writeFailed(.getSettings(id: 1), session: 99, now: h.now))
        XCTAssertEqual(h.pendingID, 1)
        h.record(h.model.writeFailed(.getSettings(id: 1), session: 7, now: h.now))
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "WRITE_FAILED"))
    }

    func testRequestIDsStayWithinAppRangeAndWrap() {
        let h = ReaderHarness()
        h.connect()
        var ids = [1]
        h.reply("OK:20:10")
        for _ in 0..<1000 {
            h.read()
            guard case .getSettings(let id)? = h.sent.last else { return XCTFail("expected GET") }
            ids.append(id)
            h.reply("OK:20:10")
        }
        XCTAssertTrue(ids.allSatisfy { ReaderSettingsLimits.requestIDs.contains($0) })
        XCTAssertEqual(ids[998], 999)
        XCTAssertEqual(ids[999], 1)
    }

    func testApplyRejectsOutOfRangeValues() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        XCTAssertTrue(h.model.canApplySettings(now: h.now))
        let count = h.sent.count
        for (power, seconds) in [(9, 10), (27, 10), (33, 10), (20, 0), (20, 61)] {
            h.apply(power, seconds)
        }
        XCTAssertEqual(h.sent.count, count)
    }

    func testApplyRequiresIdleFreshReadyReader() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.state("STOPPING")
        XCTAssertFalse(h.model.canApplySettings(now: h.now))
        h.state("READY")
        h.advance(3)
        XCTAssertFalse(h.model.canApplySettings(now: h.now))
    }

    func testOldCFGProtocolIsNeitherSentNorAccepted() {
        let h = ReaderHarness()
        h.connect()
        h.feed("\n@CFG:1:OK:20:1500\nCFG:1:OK:20:1500\n")
        XCTAssertEqual(h.pendingID, 1)
        XCTAssertNil(h.model.confirmedSettings)
        h.advance(8)
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "NO_REPLY_TIMEOUT"))
        XCTAssertTrue(h.sent.allSatisfy { $0.line.hasPrefix("CFG2:") || $0.line.hasPrefix("MODE:") })
    }

    func testReaderPoweredLaterRecoversWithManualGet() {
        let h = ReaderHarness()
        h.connect()
        h.state("FAULT")
        h.reply("ERR:TIMEOUT_UNCONFIRMED")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "TIMEOUT_UNCONFIRMED"))
        XCTAssertEqual(h.model.phase, .unconfirmed(.fault))
        XCTAssertFalse(h.snapshot.canStart)
        XCTAssertTrue(h.snapshot.canStop)
        XCTAssertTrue(h.model.canReadSettings)

        h.read()
        XCTAssertEqual(h.sent.last, .getSettings(id: 2))
        h.state("CONFIGURING")
        h.reply("OK:20:10")
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .recovered)
        XCTAssertNil(h.snapshot.startBlocker)
    }

    func testFailureMessagesKeepDiagnosticCode() {
        let unknown = ReaderMessages.settingsFailure(kind: .set, code: "SOMETHING_NEW")
        XCTAssertTrue(unknown.contains("未知錯誤"))
        XCTAssertTrue(unknown.contains("SOMETHING_NEW"))
        XCTAssertTrue(unknown.contains("讀取設定"))
        for code in ["BUSY", "RANGE", "BAD_REPLY", "READER_REJECTED", "UNSUPPORTED_PARAMS", "BACKUP_FAILED",
                     "STORAGE_UNCONFIRMED", "READBACK_MISMATCH", "TIMEOUT_UNCONFIRMED", "LINK_LOST", "CANCELLED"] {
            XCTAssertNotEqual(ReaderMessages.settingsReason(code), ReaderMessages.settingsReason("?"), code)
        }
    }
}

final class ReaderScanTests: XCTestCase {
    private let epc = ReaderHarness.epc

    func testStartBlockedUntilSettingsConfirmedAndReaderReady() {
        let h = ReaderHarness()
        XCTAssertEqual(h.snapshot.startBlocker, .linkNotReady)
        h.connect()
        XCTAssertEqual(h.snapshot.startBlocker, .settingsInProgress)
        h.reply("OK:20:10")
        XCTAssertEqual(h.snapshot.startBlocker, .noStateReport)
        h.state("STOPPING")
        XCTAssertEqual(h.snapshot.startBlocker, .readerNotReady(.stopping))
        h.state("READY")
        XCTAssertNil(h.snapshot.startBlocker)
        h.advance(3)
        XCTAssertEqual(h.snapshot.startBlocker, .noStateReport)
        h.start()
        XCTAssertEqual(h.startCount, 0)
    }

    func testManualStartSendsExactlyOneModeCommand() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start(.register)
        h.start(.register)
        h.start(.batch)
        XCTAssertEqual(h.sent.last, .mode(.register))
        XCTAssertEqual(h.startCount, 1)
        XCTAssertEqual(h.model.phase, .starting)
    }

    func testDoubleTapGuardAndSingleStopPerTransition() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.stop(user: true)                 // 誤觸雙擊
        XCTAssertEqual(h.idleCount, 0)
        XCTAssertEqual(h.model.phase, .starting)
        h.now += 0.5
        h.stop(user: true)
        h.stop(user: true)
        XCTAssertEqual(h.idleCount, 1)
        XCTAssertEqual(h.model.phase, .stopping(.app))
    }

    func testLeavingViewStopsImmediatelyEvenDuringStart() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.stop(user: false)
        XCTAssertEqual(h.idleCount, 1)
    }

    func testPreflightReadyDoesNotCompleteScan() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.advance(0.25)
        h.state("READY")
        XCTAssertEqual(h.model.phase, .starting)
        XCTAssertNil(h.model.notice)
        h.state("STOPPING")
        XCTAssertEqual(h.model.phase, .starting)
        h.state("SCANNING")
        XCTAssertEqual(h.model.phase, .scanning)
    }

    func testReadyOnlyStartTimesOutAsNotConfirmed() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.advance(4.75, reporting: "READY")
        XCTAssertEqual(h.model.phase, .starting)
        h.advance(0.25, reporting: "READY")
        XCTAssertEqual(h.model.phase, .stopping(.startTimeout))
        XCTAssertEqual(h.idleCount, 1)

        h.advance(0.5)
        h.state("READY")                   // 可能係 IDLE 之前已發出嘅舊 READY
        XCTAssertEqual(h.model.phase, .stopping(.startTimeout))
        h.advance(0.5)
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .startNotConfirmed)
    }

    func testVeryShortScanWithoutObservedScanningIsNotSuccess() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.state("STOPPING")
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .startNotConfirmed)
        XCTAssertEqual(h.idleCount, 0)
    }

    func testScanningToReadyIsDeviceAutoStopWithoutPhoneIdle() {
        let h = ReaderHarness()
        h.startScanning()
        h.advance(12, reporting: "SCANNING")
        XCTAssertEqual(h.model.phase, .scanning)
        h.state("STOPPING")
        XCTAssertEqual(h.model.phase, .stopping(.device))
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .autoStopped)
        XCTAssertEqual(h.idleCount, 0, "device is authoritative for the inactivity timeout")
        XCTAssertNil(h.snapshot.startBlocker)
    }

    func testNoFixedTotalScanDuration() {
        let h = ReaderHarness()
        h.startScanning()
        for step in 0..<1_200 {             // 10 分鐘,冇讀取/有讀取交替
            h.now += 0.5
            h.state("SCANNING")
            if step.isMultiple(of: 2) { h.feed("\(epc)\n") }
            h.tick()
        }
        XCTAssertEqual(h.idleCount, 0)
        XCTAssertEqual(h.model.phase, .scanning)
        XCTAssertEqual(h.delivered.count, 600)

        let quiet = ReaderHarness()
        quiet.startScanning()
        quiet.advance(600, reporting: "SCANNING")   // 冇標籤都唔會由 App 停止
        XCTAssertEqual(quiet.idleCount, 0)
    }

    func testRepeatedAndKnownEPCsCountAsActivityBeforeDeduplication() {
        let h = ReaderHarness()
        h.startScanning()
        for _ in 0..<5 {
            h.advance(0.5, reporting: "SCANNING")
            h.feed("\(epc)\n")
            XCTAssertEqual(h.model.lastTagActivityAt, h.now)
        }
        XCTAssertEqual(h.delivered, Array(repeating: epc, count: 5))
        XCTAssertEqual(h.snapshot.scanReadCount, 5)
        XCTAssertEqual(h.idleCount, 0)
    }

    func testTagsIgnoredWhileIdle() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.feed("\(epc)\n")
        XCTAssertTrue(h.delivered.isEmpty)
        XCTAssertNil(h.model.lastTagActivityAt)
    }

    func testFragmentedControlsMixedWithEPCsDuringScan() {
        let h = ReaderHarness()
        h.startScanning()
        h.feed("E2806894200050")
        XCTAssertTrue(h.delivered.isEmpty)
        h.feed("15E1A661E8\n\n@STATE:SCA")
        XCTAssertEqual(h.delivered.count, 1)
        h.feed("NNING\n@CFG2:77:OK:26:60\nE2806894200050")
        XCTAssertEqual(h.model.phase, .scanning)
        XCTAssertEqual(h.model.confirmedSettings, ReaderSettings(power: 20, idleSeconds: 10))
        h.feed("15E1A661E8\n")
        XCTAssertEqual(h.delivered, [epc, epc])
        h.feed("\n@STATE:READY\n")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .autoStopped)
    }

    func testManualStopWaitsForReadyConfirmation() {
        let h = ReaderHarness()
        h.startScanning()
        h.advance(1, reporting: "SCANNING")
        h.stop()
        XCTAssertEqual(h.idleCount, 1)
        XCTAssertEqual(h.model.phase, .stopping(.app))
        XCTAssertFalse(h.snapshot.canStop)
        h.state("SCANNING")                 // IDLE 之前已經喺路上
        h.state("STOPPING")
        XCTAssertEqual(h.model.phase, .stopping(.app))
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertNil(h.model.notice)
    }

    func testStopDuringStartAcceptsOnlyTrustworthyReady() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.now += 0.5
        h.stop()
        h.state("READY")                    // 可能係 MODE 之前嘅舊快照
        XCTAssertEqual(h.model.phase, .stopping(.app))
        h.now += 1
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
    }

    func testStopTimeoutRemainsUnconfirmed() {
        let h = ReaderHarness()
        h.startScanning()
        h.stop()
        h.advance(6, reporting: "STOPPING")
        XCTAssertEqual(h.model.phase, .unconfirmed(.stopUnconfirmed))
        h.advance(10, reporting: "STOPPING")
        XCTAssertEqual(h.model.phase, .unconfirmed(.stopUnconfirmed))
        XCTAssertEqual(h.idleCount, 1, "no silent IDLE resends")
        XCTAssertTrue(h.snapshot.canStop)
        XCTAssertFalse(h.snapshot.canStart)
        h.stop()
        XCTAssertEqual(h.idleCount, 2)
    }

    func testFaultDisablesStartAndAllowsStopRecovery() {
        let h = ReaderHarness()
        h.startScanning()
        h.state("FAULT")
        XCTAssertEqual(h.model.phase, .unconfirmed(.fault))
        XCTAssertFalse(h.snapshot.canStart)
        XCTAssertTrue(h.snapshot.canStop)
        h.stop()
        XCTAssertEqual(h.idleCount, 1)
        h.state("FAULT")
        XCTAssertEqual(h.model.phase, .unconfirmed(.fault))
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .recovered)
    }

    func testStopAllowedWhileSettingsTransactionPending() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.state("FAULT")
        h.read()
        XCTAssertNotNil(h.pendingID)
        h.stop()
        XCTAssertEqual(h.idleCount, 1)
        h.reply("ERR:CANCELLED")
        XCTAssertEqual(h.model.settingsOutcome, .failed(.get, code: "CANCELLED"))
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
    }

    func testLostStateReportsWhileScanningGiveUnconfirmedAndOneBestEffortIdle() {
        let h = ReaderHarness()
        h.startScanning()
        h.advance(2.75)
        XCTAssertEqual(h.model.phase, .scanning)
        h.advance(0.25)
        XCTAssertEqual(h.model.phase, .unconfirmed(.stateReportsLost))
        XCTAssertEqual(h.idleCount, 1)
        XCTAssertNotEqual(h.model.phase, .idle, "missing reports are not a stop confirmation")
        h.advance(10)
        XCTAssertEqual(h.idleCount, 1)
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertEqual(h.model.notice, .recovered)
    }

    func testLostStateReportsWhileStartingNeedsTrustworthyReady() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.advance(3)
        XCTAssertEqual(h.model.phase, .unconfirmed(.stateReportsLost))
        XCTAssertEqual(h.idleCount, 1)
        h.now += 0.5
        h.state("READY")
        XCTAssertEqual(h.model.phase, .unconfirmed(.stateReportsLost))
        h.now += 0.5
        h.state("READY")
        XCTAssertEqual(h.model.phase, .idle)
    }

    func testStartCommandWriteFailureIsUnconfirmed() {
        let h = ReaderHarness()
        h.connectReadyToScan()
        h.start()
        h.record(h.model.writeFailed(.mode(.batch), session: 7, now: h.now))
        XCTAssertEqual(h.model.phase, .unconfirmed(.commandWriteFailed))
        XCTAssertEqual(h.idleCount, 1)
    }

    func testDisconnectResetsStateAndNeverResumes() {
        let h = ReaderHarness()
        h.startScanning()
        let count = h.sent.count
        h.model.linkLost()
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertNil(h.model.confirmedSettings)
        XCTAssertNil(h.model.readerState)
        XCTAssertNil(h.model.settingsOperation)
        XCTAssertEqual(h.snapshot.startBlocker, .linkNotReady)
        h.advance(30)
        h.feed("\n@STATE:SCANNING\n\(epc)\n", session: 7)
        XCTAssertEqual(h.sent.count, count)
        XCTAssertEqual(h.model.phase, .idle)
        XCTAssertTrue(h.delivered.isEmpty)

        h.connect(session: 8)
        XCTAssertEqual(h.sent.count, count + 1)
        guard case .getSettings? = h.sent.last else { return XCTFail("reconnect should only GET") }
        XCTAssertEqual(h.startCount, 1)
    }
}
