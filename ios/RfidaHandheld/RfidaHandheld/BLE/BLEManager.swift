import CoreBluetooth
import Foundation

/// 負責同 ESP32 手提機做 BLE 連接同即時接收EPC(方案書4.2:「揀BLE而唔用Bluetooth Classic,
/// 因為BLE經CoreBluetooth framework完全開放,毋須MFi認證」)。
/// CBCentralManager 用 queue: nil,代表所有 delegate callback 都會喺 main queue 執行,
/// 所以呢個class入面可以直接更新 @Published 屬性,唔需要額外做thread hop。
final class BLEManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case poweredOff
        case unauthorized
        case disconnected
        case scanning
        case connecting
        case connected(deviceName: String)
    }

    /// 手動「開始/停止掃描」按鈕嘅逾時保護:避免使用者撳咗開始之後忘記撳停止,
    /// 讀寫模組一直發射RF、手提機電量白白被消耗。1分鐘後會自動停止,同人手撳停止效果一樣。
    static let tagScanTimeout: TimeInterval = 60

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [BLEDevice] = []
    /// 4大情景畫面嘅「開始/停止掃描」按鈕狀態,與DeviceScanView搵裝置嗰個`state == .scanning`無關。
    @Published private(set) var isTagScanning = false
    /// 畀UI顯示「將於 XX 秒後自動停止」嘅倒數。
    @Published private(set) var tagScanRemainingSeconds: Int = 0
    @Published var namePrefixFilter: String = UserDefaults.standard.string(forKey: SettingsKey.blePrefix) ?? "RFID"
    /// 示範模式(設定內嘅開關):開啟後唔會用真實CoreBluetooth,
    /// 改為模擬一個已連接嘅「示範手提機」同定時模擬掃描到EPC,方便冇實機都可以示範四大情景。
    @Published var isDemoMode: Bool = UserDefaults.standard.bool(forKey: SettingsKey.demoMode) {
        didSet {
            guard oldValue != isDemoMode else { return }
            UserDefaults.standard.set(isDemoMode, forKey: SettingsKey.demoMode)
            if isDemoMode {
                simulateDemoConnect()
            } else {
                demoTimer?.invalidate()
                demoTimer = nil
                centralManagerDidUpdateState(central)
            }
        }
    }

    /// 目前活躍嘅畫面(情景1-4其中一個)會設定呢個closure嚟接收掃描到嘅EPC。
    var onTagsRead: (([TagRead]) -> Void)?

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var parser = NUSFrameParser()
    /// 記住使用者係咪想搵緊裝置。CBCentralManager啱啱建立時state係`.unknown`,
    /// 要等藍牙權限彈窗有回應先會變成`.poweredOn`,所以App一開DeviceScanView就即刻
    /// startScan()好可能會因為呢個時間差而靜默無效;呢個flag俾我哋喺state事後變成
    /// `.poweredOn`嗰陣自動補做一次掃描,唔使使用者自己發現要撳多次「搜尋」。
    private var wantsScanning = false

    private var demoTimer: Timer?
    private var demoScanMode: ScanMode = .idle
    private var demoEmittedCount = 0

    private var tagScanTimeoutTimer: Timer?
    private var tagScanCountdownTimer: Timer?
    private var tagScanDeadline: Date?

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        if isDemoMode { simulateDemoConnect() }
    }

    func startScan() {
        wantsScanning = true
        if isDemoMode {
            simulateDemoConnect()
            return
        }
        guard central.state == .poweredOn else { return }
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
        guard connectedPeripheral == nil, state != .connecting else { return false }
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
        wantsScanning = false
        central.stopScan()
        state = .connecting
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if isDemoMode {
            demoTimer?.invalidate()
            demoTimer = nil
            state = .disconnected
            return
        }
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// 通知ESP32韌體切換掃描模式(情景1低功率隔離 vs 情景2-4批量讀取,見方案書7.1-7.2)。
    /// 示範模式下改為啟動/停止模擬掃描嘅timer,唔會實際寫BLE characteristic。
    func send(mode: ScanMode) {
        if isDemoMode {
            startDemoEmission(mode: mode)
            return
        }
        send(command: mode.rawValue)
    }

    func send(command: String) {
        guard let peripheral = connectedPeripheral,
              let rx = rxCharacteristic,
              let data = (command + "\n").data(using: .utf8) else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rx, type: type)
    }

    // MARK: - 4大情景畫面嘅「開始/停止掃描」按鈕

    /// 撳「開始掃描」:通知讀寫模組進入指定模式,並排一個1分鐘後自動`stopTagScan()`嘅逾時。
    func startTagScan(mode: ScanMode) {
        guard !isTagScanning else { return }
        isTagScanning = true
        send(mode: mode)

        let deadline = Date().addingTimeInterval(Self.tagScanTimeout)
        tagScanDeadline = deadline
        tagScanRemainingSeconds = Int(Self.tagScanTimeout)

        tagScanTimeoutTimer?.invalidate()
        tagScanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.tagScanTimeout, repeats: false) { [weak self] _ in
            self?.stopTagScan()
        }

        tagScanCountdownTimer?.invalidate()
        tagScanCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let deadline = self.tagScanDeadline else { return }
            self.tagScanRemainingSeconds = max(0, Int(deadline.timeIntervalSinceNow.rounded()))
        }
    }

    /// 撳「停止掃描」,或者1分鐘逾時自動觸發:通知讀寫模組轉返`.idle`並取消逾時計時。
    func stopTagScan() {
        guard isTagScanning else { return }
        tagScanTimeoutTimer?.invalidate()
        tagScanTimeoutTimer = nil
        tagScanCountdownTimer?.invalidate()
        tagScanCountdownTimer = nil
        tagScanDeadline = nil
        isTagScanning = false
        tagScanRemainingSeconds = 0
        send(mode: .idle)
    }

    // MARK: - 示範模式(Demo Mode)

    private func simulateDemoConnect() {
        demoTimer?.invalidate()
        demoTimer = nil
        state = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isDemoMode else { return }
            self.state = .connected(deviceName: "示範手提機(Demo)")
        }
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
        onTagsRead?(reads)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .disconnected
            if reconnectAlreadyConnectedPeripheralIfNeeded() { return }
            if wantsScanning { startScan() }
        case .unauthorized:
            state = .unauthorized
        default:
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
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([NUSProtocol.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        state = .disconnected
        stopTagScan()
    }
}

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == NUSProtocol.serviceUUID {
            peripheral.discoverCharacteristics([NUSProtocol.rxCharacteristicUUID, NUSProtocol.txCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == NUSProtocol.rxCharacteristicUUID {
                rxCharacteristic = characteristic
            } else if characteristic.uuid == NUSProtocol.txCharacteristicUUID {
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        state = .connected(deviceName: peripheral.name ?? "RFID 手提機")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == NUSProtocol.txCharacteristicUUID, let data = characteristic.value else { return }
        let reads = parser.feed(data)
        guard !reads.isEmpty else { return }
        onTagsRead?(reads)
    }
}
