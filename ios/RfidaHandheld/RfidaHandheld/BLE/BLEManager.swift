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

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var discoveredDevices: [BLEDevice] = []
    @Published var namePrefixFilter: String = UserDefaults.standard.string(forKey: SettingsKey.blePrefix) ?? "RFID"

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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        wantsScanning = true
        discoveredDevices.removeAll()
        guard central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [NUSProtocol.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        wantsScanning = false
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
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// 通知ESP32韌體切換掃描模式(情景1低功率隔離 vs 情景2-4批量讀取,見方案書7.1-7.2)。
    func send(mode: ScanMode) {
        send(command: mode.rawValue)
    }

    func send(command: String) {
        guard let peripheral = connectedPeripheral,
              let rx = rxCharacteristic,
              let data = (command + "\n").data(using: .utf8) else { return }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rx, type: type)
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .disconnected
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
