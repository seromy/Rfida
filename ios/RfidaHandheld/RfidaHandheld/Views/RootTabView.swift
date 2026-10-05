import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首頁", systemImage: "house") }

            RegisterTagView()
                .tabItem { Label("錄入新標籤", systemImage: "tag.circle") }

            CheckoutView()
                .tabItem { Label("器材出庫", systemImage: "arrow.up.right.circle") }

            ReturnCheckView()
                .tabItem { Label("器材入庫", systemImage: "arrow.down.left.circle") }

            InventoryView()
                .tabItem { Label("庫存盤點", systemImage: "list.bullet.clipboard") }
        }
    }
}
