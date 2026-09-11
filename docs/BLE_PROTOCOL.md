# ESP32 ↔ iPhone App BLE 通訊協議

呢份文件定義 iOS App(`ios/RfidaHandheld`)同 ESP32 韌體之間嘅 BLE 通訊合約。ESP32 韌體本身唔喺呢個repo嘅範圍(方案書第6節列為獨立組件),但App已經按照呢個合約實作,韌體開發時請對齊。

## 1. 為何揀 Nordic UART Service(NUS)

方案書4.2:「揀BLE而唔用Bluetooth Classic:蘋果對Classic Bluetooth外置配件有MFi認證要求,DIY項目難以負擔;BLE經CoreBluetooth framework完全開放,毋須認證。」

NUS係業界(包括Nordic官方SDK、Arduino BLE函式庫)廣泛支援嘅一個自訂GATT service,本質係一條透明嘅雙向UART管道,ESP32韌體用Arduino BLE函式庫實作NUS peripheral role即可,唔需要自己設計GATT結構。

## 2. GATT UUID(對應 `NUSProtocol.swift`)

| 角色 | UUID | 方向 |
|---|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | — |
| RX Characteristic(write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | 手機 → ESP32 |
| TX Characteristic(notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | ESP32 → 手機 |

ESP32廣播(advertise)嘅裝置名稱建議以 `RFID` 開頭(例:`RFID-01`),因為App預設用呢個字頭過濾附近裝置(可喺App「設定」畫面更改)。

## 3. TX(ESP32 → 手機):EPC 讀取結果

韌體每讀到一個標籤,經TX characteristic notify一行文字,以 `\n` 結尾:

```
<EPC_HEX>\n
<EPC_HEX>,<RSSI>\n
```

- `EPC_HEX`:標籤EPC嘅十六進位字串(偶數長度,例如 `E2801160600002042BB8A1C3`)。
- `RSSI`(選填):整數,單位dBm。
- 一個BLE封包(受MTU限制)可以包含多過一行(即一次過notify幾個標籤),App嘅 `NUSFrameParser` 會用內部buffer處理跨封包截斷嘅情況。
- **EPC offset校準**(方案書第9節已知限制):唔同UHF模組/批次,EPC喺讀寫模組傳輸frame入面嘅實際位置(offset)可能唔一樣,呢個校準應該喺韌體層做好 —— App假設收到嘅已經係乾淨、唔帶多餘header/checksum嘅EPC hex string。

## 4. RX(手機 → ESP32):模式控制指令

App會因應而家用緊邊個情景畫面,經RX characteristic write一行文字指令,以 `\n` 結尾:

| 指令 | 觸發時機 | 對應方案書 |
|---|---|---|
| `MODE:REGISTER\n` | 進入「1. 錄入新標籤」畫面 | 7.2:登記模式應降低讀寫功率(建議讀距縮到幾cm)、加強單標籤隔離 |
| `MODE:BATCH\n` | 進入「2/3/4」批量掃描畫面 | 正常/較高功率,盡量一次過讀盡成批標籤 |
| `MODE:IDLE\n` | 離開任何掃描畫面 | 停止讀寫,省電 |

韌體收到 `MODE:REGISTER` 時,建議:
1. 若UHF模組支援AT command調校功率,將輸出功率降到最低(常見規格18-26dBm可調,見方案書7.2);
2. 縮短掃描窗口,減少同時讀到多個標籤嘅機會。

韌體收到 `MODE:BATCH` 時,建議：
1. 使用模組預設/較高功率;
2. 持續輪詢讀取,盡量減少漏讀(防漏讀優先於防多讀)。

## 5. 連接生命週期

1. App掃描廣播住 NUS service UUID 嘅裝置(`CBCentralManager.scanForPeripherals(withServices:)`)。
2. 使用者喺「設定 → 裝置連接」畫面揀選裝置並連接。
3. 連接後App會discover NUS service同RX/TX characteristic,並subscribe TX嘅notify。
4. 之後每次切換情景畫面,App都會自動send相應嘅 `MODE:*` 指令 —— 韌體唔需要自己判斷情景,淨係要照住收到嘅指令調整讀寫行為。

## 6. 已知限制(見方案書第9節)

- 冇配對(pairing)/加密要求,假設喺辦公室內部信任網絡環境使用。
- 單一手提機對單一App instance;若日後要支援多部手提機同時連接,需要擴充App嘅裝置管理邏輯。
