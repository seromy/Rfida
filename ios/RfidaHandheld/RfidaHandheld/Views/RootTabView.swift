import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首頁", systemImage: "house") }

            RegisterTagView()
                .tabItem { Label("錄入標籤", systemImage: "tag.circle") }

            CheckoutView()
                .tabItem { Label("出Job登記", systemImage: "arrow.up.right.circle") }

            ReturnCheckView()
                .tabItem { Label("歸還清點", systemImage: "arrow.down.left.circle") }

            InventoryView()
                .tabItem { Label("定期盤點", systemImage: "list.bullet.clipboard") }
        }
    }
}
