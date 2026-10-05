import XCTest
@testable import RfidaHandheld

final class BLEManagerDemoTests: XCTestCase {
    private var savedDemoMode: Any?

    override func setUp() {
        super.setUp()
        savedDemoMode = UserDefaults.standard.object(forKey: SettingsKey.demoMode)
    }

    override func tearDown() {
        if let savedDemoMode {
            UserDefaults.standard.set(savedDemoMode, forKey: SettingsKey.demoMode)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.demoMode)
        }
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testDemoModeSimulatesScanningWithoutRealReaderControls() {
        let ble = BLEManager()
        ble.isDemoMode = true
        waitUntil { ble.isConnected }
        XCTAssertTrue(ble.isConnected)

        XCTAssertTrue(ble.reader.isDemo)
        XCTAssertFalse(ble.reader.canReadSettings)
        XCTAssertFalse(ble.reader.canApplySettings)
        ble.readReaderSettings()
        ble.applyReaderSettings(ReaderSettings(power: 20, idleSeconds: 10))
        XCTAssertNil(ble.reader.settingsActivity)
        XCTAssertNil(ble.reader.confirmedSettings)

        let owner = NSObject()
        var reads: [TagRead] = []
        ble.setTagReadHandler(owner: owner) { reads += $0 }
        XCTAssertTrue(ble.reader.canStart)
        ble.startTagScan(mode: .batch)
        ble.startTagScan(mode: .batch)
        XCTAssertEqual(ble.reader.phase, .scanning)
        waitUntil { !reads.isEmpty }
        XCTAssertFalse(reads.isEmpty, "demo workflow still produces reads")

        ble.stopTagScan(userInitiated: true)
        XCTAssertEqual(ble.reader.phase, .idle)
        let count = reads.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        XCTAssertEqual(reads.count, count, "demo emission stops with the scan")

        ble.removeTagReadHandler(owner: owner)
        ble.isDemoMode = false
        XCTAssertFalse(ble.reader.isDemo)
        XCTAssertFalse(ble.reader.isLinkReady)
        XCTAssertEqual(ble.reader.phase, .idle)
    }

    func testLeavingDemoScanViewStopsScan() {
        let ble = BLEManager()
        ble.isDemoMode = true
        waitUntil { ble.isConnected }
        let first = NSObject()
        ble.setTagReadHandler(owner: first) { _ in }
        ble.startTagScan(mode: .register)
        XCTAssertEqual(ble.reader.phase, .scanning)

        let second = NSObject()
        ble.setTagReadHandler(owner: second) { _ in }   // 新 tab 先 onAppear
        XCTAssertEqual(ble.reader.phase, .idle)
        ble.removeTagReadHandler(owner: first)          // 舊 tab 後 onDisappear,唔影響新 handler
        ble.isDemoMode = false
    }
}
