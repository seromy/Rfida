import SwiftUI

@main
struct RfidaHandheldApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var masterData = MasterDataStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(bleManager)
                .environmentObject(masterData)
                .task {
                    await masterData.refreshAll()
                }
        }
        .onChange(of: scenePhase) { newPhase in
            // 入背景就盡力停止掃描;返嚟之後唔會自動恢復,要使用者再按「掃描」。
            if newPhase == .background { bleManager.handleAppEnteredBackground() }
        }
    }
}
