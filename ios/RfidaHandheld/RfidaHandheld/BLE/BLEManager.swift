import CoreBluetooth
import Foundation

/// 負責同 ESP32 手提機做 BLE 連接同即時接收EPC(方案書4.2:「揀BLE而唔用Bluetooth Classic,
/// 因為BLE經CoreBluetooth framework完全開放,毋須MFi認證」)。
/// CBCentralManager 用 queue: nil,代表所有 delegate callback 都會喺 main queue 執行,
/// 所以呢個class入面可以直接更新 @Published 屬性,唔需要額外做thread hop。
///
/// 掃描同設定嘅狀態邏輯喺 `ReaderSessionModel`(純邏輯、可測試);呢度只負責 CoreBluetooth、
/// session 範圍、計時器同將結果交畀畫面。
final class BLEManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case poweredOff
        case unauthorized
        case disconnected
        case scanning
        case connecting
        case connected(deviceName: String)
    }

    /// 掃描/設定逾時檢查嘅間隔。只檢查 deadline,唔會因本地倒數而發 IDLE。
    private static let tickInterval: TimeInterval = 0.25

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [BLEDevice] = []
    /// 讀卡器掃描/設定狀態(4大情景掃描按鈕同設定畫面用)。只喺內容有變先發布,避免計時器令畫面不停重繪。
    @Published private(set) var reader = ReaderSnapshot()
    @Published var namePrefixFilter: String = UserDefaults.standard.string(forKey: SettingsKey.blePrefix) ?? "RFID"
    /// 示範模式(設定內嘅開關):開啟後唔會用真實CoreBluetooth,
    /// 改為模擬一個已連接嘅「示範手提機」同模擬掃描到EPC,方便冇實機都可以示範四大情景。
    @Published var isDemoMode: Bool = UserDefaults.standard.bool(forKey: SettingsKey.demoMode) {
        didSet {
            guard oldValue != isDemoMode else { return }
            UserDefaults.standard.set(isDemoMode, forKey: SettingsKey.demoMode)
            if isDemoMode {
                // 示範模式同真實硬件隔離:盡力停止真實讀卡器再斷開,之後唔再處理真實BLE資料。
                disconnectRealHardware()
                simulateDemoConnect()
            } else {
                stopDemoScan()
                demoTimer?.invalidate()
                demoTimer = nil
                centralManagerDidUpdateState(central)
            }
            refreshReader()
        }
    }

    /// 目前活躍嘅畫面(情景1-4其中一個)經`setTagReadHandler`設定呢個closure嚟接收掃描到嘅EPC。
    private var onTagsRead: (([TagRead]) -> Void)?
    /// 邊個畫面(以佢嘅viewModel識別)擁有`onTagsRead`。TabView切換tab時,新tab嘅onAppear
    /// 通常會早過舊tab嘅onDisappear觸發;如果舊tab直接清走closure,就會連新tab啱啱設定嘅都清埋,
    /// 結果手提機照樣傳EPC過嚟但冇人接收 ——「顯示已連接,但實際用唔到」,要返首頁再入先回復。
    private var tagReadOwner: ObjectIdentifier?
    /// 開始今次掃描嘅畫面;換咗畫面之後仲喺路上嘅EPC唔會流入新畫面。
    private var scanOwner: ObjectIdentifier?

    func setTagReadHandler(owner: AnyObject, _ handler: @escaping ([TagRead]) -> Void) {
        let id = ObjectIdentifier(owner)
        // 換咗畫面就停低上一個畫面未完嘅掃描,免得佢讀到嘅標籤流入新畫面。
        if tagReadOwner != id { stopTagScan() }
        tagReadOwner = id
        onTagsRead = handler
    }

    /// 只有仍然擁有handler嘅畫面先會清除,避免誤清新畫面嘅closure。
    func removeTagReadHandler(owner: AnyObject) {
        guard tagReadOwner == ObjectIdentifier(owner) else { return }
        stopTagScan()
        tagReadOwner = nil
        onTagsRead = nil
    }

    private var central: CBCentralManager!
    private var connectingPeripheral: CBPeripheral?
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    /// 記住使用者係咪想搵緊裝置。CBCentralManager啱啱建立時state係`.unknown`,
    /// 要等藍牙權限彈窗有回應先會變成`.poweredOn`,所以App一開DeviceScanView就即刻
    /// startScan()好可能會因為呢個時間差而靜默無效;呢個flag俾我哋喺state事後變成
    /// `.poweredOn`嗰陣自動補做一次掃描,唔使使用者自己發現要撳多次「搜尋」。
    private var wantsScanning = false

    private var model = ReaderSessionModel()
    private var sessionCounter = 0
    /// 只有 RX 已找到而且 TX 訂閱已確認先會有值;舊 session 嘅 callback 會被忽略。
    private var activeSession: Int?
    /// Write-with-response 嘅 callback 按寫入次序返嚟,用 FIFO 對返係邊個指令。
    private var pendingWrites: [ReaderCommand] = []
    private var tickTimer: Timer?

    private var demoTimer: Timer?
    private var demoScanMode: ScanMode = .idle
    private var demoEmittedCount = 0
    private var demoScanning = false

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Monotonic 時間,唔受使用者改系統時鐘影響。
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        if isDemoMode { simulateDemoConnect() }
        refreshReader()
    }

    func startScan() {
        wantsScanning = true
        if isDemoMode {
            simulateDemoConnect()
            return
        }
        guard central.state == .poweredOn else { return }
        // DeviceScanView每次重新出現(例如切換返其他tab再返嚟)都會喺onAppear撳呢個function,
        // 若果嗰陣已經連接緊裝置,唔應該再開一次主動掃描 —— 掃描期間嘅無線電負載會干擾緊住嘅
        // GATT連接,曾經導致「App顯示已連接,但實際上藍牙已經斷咗」。
        guard !isConnected else { return }
        if reconnectAlreadyConnectedPeripheralIfNeeded() { return }
        discoveredDevices.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: [NUSProtocol.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// BLE peripheral一旦已經同呢部iPhone有連接(包括之前連接過、由系統藍牙layer keep住嗰種),
    /// 就通常唔會再廣播,`scanForPeripherals`就永遠搵唔返佢 —— 呢個係「iOS藍牙清單話已連接,
    /// App卻一直顯示未連接」嘅根本原因。呢度用`retrieveConnectedPeripherals`直接攞返呢啲
    /// 裝置(唔使靠廣播),搵到就自動幫使用者連接,唔使佢自己喺清單度揀。
    /// 回傳true代表已經觸發緊一次連接(呼叫方應該避免同時再開始掃描,以免覆寫`.connecting`狀態)。
    @discardableResult
    private func reconnectAlreadyConnectedPeripheralIfNeeded() -> Bool {
        guard !isDemoMode, connectedPeripheral == nil, state != .connecting else { return false }
        let alreadyConnected = central.retrieveConnectedPeripherals(withServices: [NUSProtocol.serviceUUID])
            .filter { peripheral in
                let name = peripheral.name ?? ""
                return namePrefixFilter.isEmpty || name.hasPrefix(namePrefixFilter)
            }
        guard let peripheral = alreadyConnected.first else { return false }
        let device = BLEDevice(id: peripheral.identifier, peripheral: peripheral, name: peripheral.name ?? "RFID 手提機", rssi: 0)
        connect(device)
        return true
    }

    func stopScan() {
        wantsScanning = false
        if isDemoMode { return }
        central.stopScan()
        if state == .scanning { state = .disconnected }
    }

    func connect(_ device: BLEDevice) {
        guard !isDemoMode else { return }
        wantsScanning = false
        central.stopScan()
        if let current = connectedPeripheral ?? connectingPeripheral {
            if current.identifier == device.peripheral.identifier { return }
            // 換裝置:盡力停止舊讀卡器,再清走舊 session。
            perform(model.stopScan(userInitiated: false, now: now))
            central.cancelPeripheralConnection(current)
            resetLink()
        }
        connectingPeripheral = device.peripheral
        state = .connecting
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if isDemoMode {
            stopDemoScan()
            demoTimer?.invalidate()
            demoTimer = nil
            state = .disconnected
            refreshReader()
            return
        }
        guard let peripheral = connectedPeripheral ?? connectingPeripheral else { return }
        // 斷開前盡力停止掃描;韌體喺斷線/取消訂閱時亦會自己停止。
        perform(model.stopScan(userInitiated: false, now: now))
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: - 4大情景畫面嘅「掃描/停止掃描」按鈕

    /// 手動開始掃描。冇固定掃描時長:讀卡器由韌體按「無讀取自動停止」秒數自行停止,或者等使用者按停止。
    func startTagScan(mode: ScanMode) {
        if isDemoMode {
            startDemoScan(mode: mode)
            return
        }
        let effects = model.startScan(mode: mode, now: now)
        if !effects.isEmpty { scanOwner = tagReadOwner }
        perform(effects)
    }

    /// 發送 IDLE 並等待讀卡器 READY 確認。`userInitiated` 用嚟過濾誤觸雙擊;
    /// 離開畫面、App 入背景等情況用預設值,會即刻停止。
    func stopTagScan(userInitiated: Bool = false) {
        if isDemoMode {
            stopDemoScan()
            return
        }
        perform(model.stopScan(userInitiated: userInitiated, now: now))
    }

    /// App 入背景:盡力停止掃描,返嚟之後唔會自動恢復。
    func handleAppEnteredBackground() {
        stopTagScan()
    }

    // MARK: - 讀卡器設定(CFG2)

    func readReaderSettings() {
        guard !isDemoMode else { return }
        perform(model.readSettings(now: now))
    }

    /// 只喺使用者明確按「套用設定」時先會發出 SET;成功與否要等手提機回覆 OK 同數值完全吻合。
    func applyReaderSettings(_ settings: ReaderSettings) {
        guard !isDemoMode else { return }
        perform(model.applySettings(settings, now: now))
    }

    // MARK: - Session / 寫入

    private func perform(_ effects: [ReaderEffect]) {
        for effect in effects {
            switch effect {
            case .send(let command):
                write(command)
            case .tags(let reads):
                deliverTags(reads)
            }
        }
        refreshReader()
    }

    private func deliverTags(_ reads: [TagRead]) {
        if let scanOwner, scanOwner != tagReadOwner { return }
        onTagsRead?(reads)
    }

    private func write(_ command: ReaderCommand) {
        guard !isDemoMode, activeSession != nil, let peripheral = connectedPeripheral, let rx = rxCharacteristic else { return }
        let data = command.data
        let type: CBCharacteristicWriteType = rx.properties.contains(.write) ? .withResponse : .withoutResponse
        // 指令最長19 bytes,預設MTU已經放得落;保險起見照最大長度分段,韌體會按LF重組。
        let maxLength = max(1, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxLength, data.count)
            if type == .withResponse { pendingWrites.append(command) }
            peripheral.writeValue(data.subdata(in: offset..<end), for: rx, type: type)
            offset = end
        }
    }

    private func refreshReader() {
        let next = isDemoMode ? ReaderSnapshot.demo(isConnected: isConnected, isScanning: demoScanning) : model.snapshot(now: now)
        if next != reader { reader = next }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isDemoMode, self.activeSession != nil else { return }
            self.perform(self.model.tick(now: self.now))
        }
        tickTimer = timer
        // 使用 common mode,捲動畫面時仍然會檢查逾時。
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 斷線、藍牙不可用、換裝置或訂閱失效:清走 parser、pending ID、計時器、已確認設定同掃描狀態。
    private func resetLink() {
        tickTimer?.invalidate()
        tickTimer = nil
        activeSession = nil
        pendingWrites.removeAll()
        connectingPeripheral = nil
        connectedPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        scanOwner = nil
        model.linkLost()
        refreshReader()
    }

    private func failLink(_ peripheral: CBPeripheral) {
        central.cancelPeripheralConnection(peripheral)
        resetLink()
        if !isDemoMode { state = .disconnected }
    }

    private func disconnectRealHardware() {
        wantsScanning = false
        central.stopScan()
        if let peripheral = connectedPeripheral ?? connectingPeripheral {
            perform(model.stopScan(userInitiated: false, now: now))
            central.cancelPeripheralConnection(peripheral)
        }
        resetLink()
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        connectedPeripheral?.identifier == peripheral.identifier
    }

    // MARK: - 示範模式(Demo Mode)

    private func simulateDemoConnect() {
        demoTimer?.invalidate()
        demoTimer = nil
        demoScanning = false
        state = .connecting
        refreshReader()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isDemoMode else { return }
            self.state = .connected(deviceName: "示範手提機(Demo)")
            self.refreshReader()
        }
    }

    /// 示範模式嘅掃描只係本地模擬:唔會寫BLE,亦唔會影響真實讀卡器嘅設定或計時。
    /// 模擬標籤會持續出現,所以同真機一樣要按「停止掃描」或離開畫面先會停。
    private func startDemoScan(mode: ScanMode) {
        guard isConnected, !demoScanning, mode != .idle else { return }
        demoScanning = true
        scanOwner = tagReadOwner
        startDemoEmission(mode: mode)
        refreshReader()
    }

    private func stopDemoScan() {
        guard demoScanning else { return }
        demoScanning = false
        startDemoEmission(mode: .idle)
        refreshReader()
    }

    private func startDemoEmission(mode: ScanMode) {
        demoTimer?.invalidate()
        demoTimer = nil
        demoScanMode = mode
        demoEmittedCount = 0
        guard mode != .idle else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { [weak self] _ in
            self?.emitDemoReads()
        }
    }

    /// 模擬讀寫模組讀到EPC:情景1(register)每次讀一件(偶爾同時讀兩件,
    /// 模擬多標籤衝突警告);情景2-4(batch)逐件循環讀盡示範器材清單。
    private func emitDemoReads() {
        let reads: [TagRead]
        switch demoScanMode {
        case .idle:
            return
        case .register:
            let pool = DemoData.unregisteredEPCs
            let isMultiTagTick = demoEmittedCount > 0 && demoEmittedCount % 4 == 3
            let count = isMultiTagTick ? 2 : 1
            reads = (0..<count).map { offset in
                TagRead(epc: pool[(demoEmittedCount + offset) % pool.count], rssi: Int.random(in: -70 ... -40), timestamp: Date())
            }
            demoEmittedCount += count
        case .batch:
            let pool = DemoData.equipment.map(\.epc)
            let epc = pool[demoEmittedCount % pool.count]
            reads = [TagRead(epc: epc, rssi: Int.random(in: -70 ... -40), timestamp: Date())]
            demoEmittedCount += 1
        }
        deliverTags(reads)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard !isDemoMode else { return }
            state = .disconnected
            if reconnectAlreadyConnectedPeripheralIfNeeded() { return }
            if wantsScanning { startScan() }
        case .unauthorized:
            // 藍牙不可用時 iOS 唔會逐個 peripheral 通知斷線,要自己清走 session。
            resetLink()
            guard !isDemoMode else { return }
            state = .unauthorized
        default:
            resetLink()
            guard !isDemoMode else { return }
            state = .poweredOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "未知裝置"
        guard namePrefixFilter.isEmpty || name.hasPrefix(namePrefixFilter) else { return }

        let device = BLEDevice(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !isDemoMode, connectingPeripheral?.identifier == peripheral.identifier else {
            // 唔係而家想連接嘅裝置(例如已取消嘅舊請求或者示範模式開緊):唔保留連接。
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectingPeripheral = nil
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([NUSProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectingPeripheral?.identifier == peripheral.identifier else { return }
        connectingPeripheral = nil
        guard !isDemoMode else { return }
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isCurrent(peripheral) || connectingPeripheral?.identifier == peripheral.identifier else { return }
        resetLink()
        guard !isDemoMode else { return }
        state = .disconnected
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == NUSProtocol.serviceUUID }) else {
            failLink(peripheral)
            return
        }
        peripheral.discoverCharacteristics([NUSProtocol.rxCharacteristicUUID, NUSProtocol.txCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral), service.uuid == NUSProtocol.serviceUUID else { return }
        guard error == nil,
              let characteristics = service.characteristics,
              let rx = characteristics.first(where: { $0.uuid == NUSProtocol.rxCharacteristicUUID }),
              let tx = characteristics.first(where: { $0.uuid == NUSProtocol.txCharacteristicUUID }) else {
            failLink(peripheral)
            return
        }
        rxCharacteristic = rx
        txCharacteristic = tx
        // 要等 didUpdateNotificationStateFor 確認訂閱成功,先當連接可用。
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == NUSProtocol.txCharacteristicUUID else { return }
        guard error == nil, characteristic.isNotifying, rxCharacteristic != nil, !isDemoMode else {
            // 訂閱失敗或者被取消:韌體會自己停止;App 當連接失效,要重新連接。
            failLink(peripheral)
            return
        }
        guard activeSession == nil else { return }
        sessionCounter += 1
        activeSession = sessionCounter
        txCharacteristic = characteristic
        startTickTimer()
        state = .connected(deviceName: peripheral.name ?? "RFID 手提機")
        perform(model.linkReady(session: sessionCounter, now: now))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !isDemoMode, isCurrent(peripheral), characteristic.uuid == NUSProtocol.txCharacteristicUUID,
              error == nil, let session = activeSession, let data = characteristic.value else { return }
        perform(model.receive(data, session: session, now: now))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == NUSProtocol.rxCharacteristicUUID,
              let session = activeSession, !pendingWrites.isEmpty else { return }
        let command = pendingWrites.removeFirst()
        // 寫入成功只代表 BLE 送達,唔代表設定成功;設定要等 @CFG2 OK。
        guard error != nil else { return }
        perform(model.writeFailed(command, session: session, now: now))
    }
}
