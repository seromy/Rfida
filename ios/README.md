# RFID 手提機 iOS App

呢個係「RFID器材出入管理系統 DIY建置方案書」入面所講嘅 iPhone App 部分 —— 作為RFID手提機(ESP32 + YRM100 UHF讀寫模組)嘅「畫面」:即時UI、員工/Job揀選,並經BLE接收掃描到嘅EPC、經WiFi將業務資料提交俾後台伺服器。

技術棧同方案書第6節一致:**Swift、SwiftUI、CoreBluetooth**,最低支援 iOS 16.0。

## 專案結構

```
ios/RfidaHandheld/
  RfidaHandheld.xcodeproj/       # Xcode 專案(直接用 Xcode 開啟)
  RfidaHandheld/
    App/                        # App 進入點
    Models/                     # 器材/員工/Job/掃描紀錄等資料模型
    BLE/                        # CoreBluetooth 連接管理 + Nordic UART Service 協議解析
    Networking/                 # 後台 REST API client
    Data/                       # 全域資料快取、情景3清單比對邏輯
    ViewModels/                 # 四大情景各自嘅業務邏輯
    Views/                      # SwiftUI 畫面
    Utilities/                  # 共用常數/extension
    Assets.xcassets/            # App圖示、強調色
```

## 開啟與執行

1. 用 Xcode 15 或以上版本開啟 `RfidaHandheld.xcodeproj`。
2. 喺 Signing & Capabilities 揀返你自己嘅 Apple Developer Team(專案內建 `Automatic` 簽署,只需選Team),並視需要修改 Bundle Identifier(預設 `com.rfida.RfidaHandheld`)。
3. 接駁iPhone(需要iOS 16+;CoreBluetooth喺模擬器唔可以連接真實藍牙裝置,建議用真機測試BLE功能),Build & Run。
4. 首次啟動時,iOS會彈出藍牙使用權限請求(對應Info設定入面嘅 `NSBluetoothAlwaysUsageDescription`),請允許。

## App 對應方案書嘅四大使用情景

| Tab | 情景 | 重點邏輯 |
|---|---|---|
| 1. 錄入標籤 | 情景1:錄入新標籤 | 只認「未登記」嘅EPC;偵測到多過一個未登記標籤時顯示警告並停用登記操作(方案書7.3) |
| 2. 出Job登記 | 情景2:出發前登記 | 批量累積掃描到嘅唯一EPC,選員工/Job後提交 |
| 3. 歸還清點 | 情景3:返office前清點 | 讀取該Job出Job時嘅「應有清單」,同即時掃描結果自動比對,即時顯示缺件(方案書7.4,原方案書標註「未實作,建議加」,呢個App已實作) |
| 4. 定期盤點 | 情景4:定期盤點 | 大量標籤批量掃描,接近讀寫模組tag buffer上限(方案書7.5)時提示分批 |

首頁(Home)顯示BLE連接狀態同器材/員工/Job資料概況;設定畫面可設定後台伺服器網址、BLE裝置名稱過濾字串,以及掃描提示聲嘅靜音開關。

四個情景每次成功掃描到「新」標籤(即之前未見過嘅EPC)都會發出一下短嗶聲(`Utilities/ScanSoundPlayer.swift`,即時合成、唔需要綁定音效檔案),提示聲唔跟手機側邊靜音撥掣,只受「設定」入面嘅靜音模式開關控制。

## 對外介面

呢個App需要連接兩個依方案書設計嘅組件:

- **ESP32韌體**(Arduino/C++,BLE Nordic UART Service模式,唔喺呢個repo範圍內):協議定義見 [`docs/BLE_PROTOCOL.md`](../docs/BLE_PROTOCOL.md)。
- **Flask + SQLite 後台伺服器**(REST API + 網頁Dashboard,已包含喺呢個repo嘅 [`server/`](../server/)):合約定義見 [`docs/API_CONTRACT.md`](../docs/API_CONTRACT.md)。

兩份文件已經按照App現有實作寫定;如果實際實作有出入,對應調整 `BLE/NUSProtocol.swift`、`Networking/APIClient.swift` 或 `server/` 即可。

## 已知限制(對應方案書第9節)

- 冇獨立登入/權限系統,假設喺辦公室內部信任網絡環境使用。
- 單一手提機、單一App instance對單一後台;未支援多部手提機同時使用嘅中央同步架構。
- EPC喺讀寫模組frame入面嘅offset需要用實物模組校準 —— 呢個校準工作喺ESP32韌體層做,App假設收到嘅已經係乾淨嘅EPC hex string。
