import SwiftUI

@main
struct RfidaHandheldApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var masterData = MasterDataStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(bleManager)
                .environmentObject(masterData)
                .task {
                    await masterData.refreshAll()
                }
        }
    }
}
