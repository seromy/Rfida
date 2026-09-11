import CoreBluetooth
import Foundation

struct BLEDevice: Identifiable, Hashable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
