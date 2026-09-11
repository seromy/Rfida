import SwiftUI

/// 方案書7.3:登記模式下偵測到多過一個未登記標籤時嘅警告。
struct MultiTagWarningView: View {
    let count: Int

    var body: some View {
        Label {
            Text("偵測到 \(count) 個未登記標籤,請用RF屏蔽袋或將器材分開,確保讀寫頭附近淨係得一件器材先可以繼續。")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
    }
}
