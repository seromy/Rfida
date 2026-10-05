# RFID 手提機 iOS App

呢個係「RFID器材出入管理系統 DIY建置方案書」入面所講嘅 iPhone App 部分 —— 作為RFID手提機(ESP32 + YRM100 UHF讀寫模組)嘅「畫面」:即時UI、公司/Job揀選,並經BLE接收掃描到嘅EPC、經WiFi將業務資料提交俾後台伺服器。

技術棧同方案書第6節一致:**Swift、SwiftUI、CoreBluetooth**,最低支援 iOS 16.0。

## 專案結構

```
ios/RfidaHandheld/
  RfidaHandheld.xcodeproj/       # Xcode 專案(直接用 Xcode 開啟)
  RfidaHandheld/
    App/                        # App 進入點
    Models/                     # 器材/公司/Job/掃描紀錄等資料模型
    BLE/                        # CoreBluetooth 連接管理、NUS 協議解析、讀卡器掃描/設定狀態機
    Networking/                 # 後台 REST API client
    Data/                       # 全域資料快取、情景3清單比對邏輯
    ViewModels/                 # 四大情景各自嘅業務邏輯
    Views/                      # SwiftUI 畫面
    Utilities/                  # 共用常數/extension
    Assets.xcassets/            # App圖示、強調色
  RfidaHandheldTests/           # 單元測試(BLE 解析、掃描/設定狀態機、示範模式)
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
| 2. 出Job登記 | 情景2:出發前登記 | 批量累積掃描到嘅唯一EPC,選公司/Job後提交 |
| 3. 歸還清點 | 情景3:返office前清點 | 讀取該Job出Job時嘅「應有清單」,同即時掃描結果自動比對,即時顯示缺件(方案書7.4,原方案書標註「未實作,建議加」,呢個App已實作) |
| 4. 定期盤點 | 情景4:定期盤點 | 大量標籤批量掃描,接近讀寫模組tag buffer上限(方案書7.5)時提示分批 |

首頁(Home)顯示BLE連接狀態同器材/公司/Job資料概況;設定畫面可設定讀卡器功率同無讀取自動停止秒數、後台伺服器網址、BLE裝置名稱過濾字串,以及掃描提示聲嘅靜音開關。

### 手動掃描同無讀取自動停止

四個情景畫面都係按「掃描」開始、按「停止掃描」停止,冇固定掃描時長。讀卡器(ESP32 韌體)連續一段時間讀唔到標籤就會自己停止,預設 10 秒,可喺「設定 → 讀卡器設定」改為 1–60 秒。每次讀到標籤都會重新計時,包括同一張標籤,所以標籤一直喺範圍內就會一直掃描。App 只跟讀卡器回報嘅狀態更新按鈕,唔會用手機倒數去停止讀卡器。離開畫面或者 App 入背景都會停止掃描,返嚟之後唔會自動恢復。協議細節見 [`docs/BLE_PROTOCOL.md`](../docs/BLE_PROTOCOL.md)。

「讀卡器設定」入面:「讀取設定」會向手提機查詢目前數值(每次連接亦會自動查詢一次);「套用設定」先會發送改動,要等讀卡器回覆確認先算成功。畫面分開顯示「讀卡器已確認數值」同「草稿」。

### 示範模式(Demo Mode)

設定畫面入面有個「示範模式」開關,開啟後App會自動連接一部模擬嘅「示範手提機」,並改用內置嘅假器材/公司/Job資料(`Data/DemoData.swift`、`Networking/DemoDataProvider.swift`),四個情景畫面都會定時模擬掃描到EPC,唔需要真實ESP32手提機或後台伺服器就可以完整行一次四大使用情景,方便Demo或App Store審查。關閉開關即刻返回正常模式,改用真實BLE同後台伺服器。

四個情景每次成功掃描到「新」標籤(即之前未見過嘅EPC)都會發出一下短嗶聲(`Utilities/ScanSoundPlayer.swift`,即時合成、唔需要綁定音效檔案),提示聲唔跟手機側邊靜音撥掣,只受「設定」入面嘅靜音模式開關控制。

## 自動測試

`RfidaHandheldTests` 測試 BLE 行解析、CFG2 設定、掃描狀態機同示範模式(唔需要實機):

```
xcodebuild test -project RfidaHandheld/RfidaHandheld.xcodeproj -scheme RfidaHandheld -destination 'platform=iOS Simulator,name=iPhone 17'
```

## 實機測試步驟(讀卡器設定同手動掃描)

1. 上載配套韌體（`RfidaBLEIdleSettings.ino`）到 ESP32，並安裝更新後的 App。連接 RFID-01，接通讀卡器電源，到「設定 → 讀卡器設定」按「讀取設定」。應該看到功率等級 20、無讀取自動停止 10 秒（除非之前已儲存其他數值）。
2. 在任何掃描畫面按「掃描」，把一張標籤放近讀卡器，然後拿走。最後一次讀到標籤後大約 10 秒，讀卡器應自動停止，App 的按鈕回到「掃描」。
3. 再按「掃描」，在自動停止之前按「停止掃描」。App 會顯示「正在停止…」，等讀卡器確認後才回到「掃描」。
4. 把一張可以一直讀到的標籤留在範圍內，掃描應會持續。確認一會兒後，手動按「停止掃描」。因為沒有總時長上限，請不要在無人看管下讓它一直掃描。
5. 只把「無讀取自動停止」改為 5 秒，功率保持 20，按「套用設定」，等到顯示「讀卡器已確認套用設定」。重複第 2 步（拿走標籤後約 5 秒停止）。然後關掉手提機電源再開、重新連接，按「讀取設定」，確認仍然是 5 秒。
6. 功率調整只在有需要時另外測試：每次小幅調整、短時間測試。不要預設改回 33；目前功率 20 已改善發熱。

注意：功率數值是讀卡器的原始等級，並非實測 dBm；App 無法保證讀卡器的無線電已物理關閉。如 App 顯示 FAULT（未能確認停止），請關閉讀卡器電源並檢查電源和接線。

## 對外介面

呢個App需要連接兩個依方案書設計嘅組件:

- **ESP32韌體**(Arduino/C++,BLE Nordic UART Service模式,唔喺呢個repo範圍內):協議定義見 [`docs/BLE_PROTOCOL.md`](../docs/BLE_PROTOCOL.md)。
- **Flask + SQLite 後台伺服器**(REST API + 網頁Dashboard,已包含喺呢個repo嘅 [`server/`](../server/)):合約定義見 [`docs/API_CONTRACT.md`](../docs/API_CONTRACT.md)。

兩份文件已經按照App現有實作寫定;如果實際實作有出入,對應調整 `BLE/NUSProtocol.swift`、`Networking/APIClient.swift` 或 `server/` 即可。

## 已知限制(對應方案書第9節)

- 冇獨立登入/權限系統,假設喺辦公室內部信任網絡環境使用。
- 單一手提機、單一App instance對單一後台;未支援多部手提機同時使用嘅中央同步架構。
- EPC喺讀寫模組frame入面嘅offset需要用實物模組校準 —— 呢個校準工作喺ESP32韌體層做,App假設收到嘅已經係乾淨嘅EPC hex string。
