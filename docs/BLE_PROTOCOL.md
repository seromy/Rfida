# ESP32 ↔ iPhone App BLE 通訊協議(v2)

呢份文件定義 iOS App(`ios/RfidaHandheld`)同 ESP32 韌體之間嘅 BLE 通訊合約。ESP32 韌體本身唔喺呢個repo嘅範圍(方案書第6節列為獨立組件),但App已經按照呢個合約實作,韌體開發時請對齊。配套韌體係 `RfidaBLEIdleSettings.ino`(Arduino ESP32 core 3.x)。

v2 重點:**手動開始/停止掃描**、**無讀取自動停止**(由韌體計時)、**CFG2 讀取/套用讀卡器設定**、**@STATE 狀態快照**。v2 同舊 `CFG`(以毫秒計時長)協議刻意唔兼容,App 唔會 fallback 去舊 `CFG`。

## 1. 為何揀 Nordic UART Service(NUS)

方案書4.2:「揀BLE而唔用Bluetooth Classic:蘋果對Classic Bluetooth外置配件有MFi認證要求,DIY項目難以負擔;BLE經CoreBluetooth framework完全開放,毋須認證。」

NUS係業界(包括Nordic官方SDK、Arduino BLE函式庫)廣泛支援嘅一個自訂GATT service,本質係一條透明嘅雙向UART管道,ESP32韌體用Arduino BLE函式庫實作NUS peripheral role即可,唔需要自己設計GATT結構。

## 2. GATT UUID(對應 `NUSProtocol.swift`)

| 角色 | UUID | 方向 |
|---|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | — |
| RX Characteristic(write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | 手機 → ESP32 |
| TX Characteristic(notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | ESP32 → 手機 |

裝置名稱:`RFID-01`。App預設用 `RFID` 字頭過濾附近裝置(可喺App「設定」畫面更改)。

## 3. 通用文字格式

- 所有行都係 ASCII,以 LF 結尾(下文 `\n` 代表真正嘅 LF 字元,唔係反斜線加 n)。
- 一個 notification 可以只係一行嘅一部分,亦可以包含幾行。App 會保留未完嘅尾段、限制每行長度(256 bytes,超長行成行丟棄)、忽略空白行。
- App **先分流控制行**(以 `@` 開頭),再解析 EPC;`@CFG2`、`@STATE` 或任何未知 `@` 行都唔會被當成標籤。
- App 只發文字指令;唔會由手機直接發讀寫模組嘅二進制指令。
- App 用 write-with-response(韌體 RX 同時支援 write 同 write-without-response)。BLE 寫入完成**唔代表**設定成功。

## 4. TX(ESP32 → 手機)

### 4.1 EPC 讀取結果(不變)

```
<EPC_HEX>\n
<EPC_HEX>,<RSSI>\n
```

- `EPC_HEX`:標籤EPC嘅十六進位字串(偶數長度、8–128 字元,例如 `E280689420005015E1A661E8`)。韌體只會喺 SCANNING 時轉發即時 EPC,而且每行前面會加一個 LF 以沖走殘缺行。
- `RSSI`(選填,legacy):整數。
- **EPC offset校準**(方案書第9節已知限制):唔同UHF模組/批次,EPC喺讀寫模組傳輸frame入面嘅實際位置(offset)可能唔一樣,呢個校準應該喺韌體層做好 —— App假設收到嘅已經係乾淨、唔帶多餘header/checksum嘅EPC hex string。
- App 喺業務層(各情景 ViewModel)先做去重;BLE 層每個有效 EPC(包括重複同已登記標籤)都會交落去。

### 4.2 狀態快照 `@STATE`

```
@STATE:STARTING\n
@STATE:SCANNING\n
@STATE:STOPPING\n
@STATE:READY\n
@STATE:FAULT\n
```

另有 `UNKNOWN`、`CONFIGURING`。每行 ≤ 20 bytes,前面可能有一個空行。韌體訂閱期間大約每 500ms 發一次,但**唔保證**每個短暫狀態都會出現。快照冇 request ID,只適用於當前連接,亦唔係設定回覆。

| 狀態 | 意思 |
|---|---|
| `READY` | 讀卡器已確認 STOP ACK,待命 |
| `STARTING` / `SCANNING` | 開始中 / 掃描中 |
| `STOPPING` | 已發 STOP,等緊確認(未停) |
| `FAULT` | STOP 未能確認(重試 3 次失敗);RF 狀態未知 |
| `CONFIGURING` | 正在處理 CFG2 |

### 4.3 設定回覆 `@CFG2`

```
@CFG2:<id>:OK:<actualPower>:<idleSeconds>\n
@CFG2:<id>:ERR:<reason>\n
```

例如 `@CFG2:42:OK:20:10`、`@CFG2:44:ERR:BUSY`。所有數字係嚴格十進制整數。

錯誤碼:`BUSY`、`RANGE`、`BAD_REPLY`、`READER_REJECTED`、`UNSUPPORTED_PARAMS`、`BACKUP_FAILED`、`STORAGE_UNCONFIRMED`、`READBACK_MISMATCH`、`TIMEOUT_UNCONFIRMED`、`LINK_LOST`、`CANCELLED`。App 對未知錯誤碼顯示通用訊息並保留代碼。

## 5. RX(手機 → ESP32)

### 5.1 掃描控制

| 指令 | 意思 |
|---|---|
| `MODE:REGISTER\n` | 開始掃描(情景1) |
| `MODE:BATCH\n` | 開始掃描(情景2/3/4) |
| `MODE:IDLE\n` | 停止掃描 |

- 兩個開始模式都用同一個全域功率設定;韌體**唔會**按模式自動加大功率。
- **冇固定掃描總時長。** 韌體喺「連續 N 秒冇讀到有效即時 EPC」時自動停止(N 預設 10,可設 1–60)。每個有效 EPC 都會重新計時,**包括同一張標籤重複讀到、已登記標籤**;唔係「距離上一張新標籤」。標籤一直喺範圍內就會一直掃描,直至手動停止。
- 如果一直冇讀到標籤,計時由讀卡器成功 START ACK 開始。
- 開始指令會先做一次 STOP preflight,所以 SCANNING 之前可能見到 STOPPING/READY。
- 讀卡器忙碌、設定未完成或者連接未就緒時,韌體可能**靜默忽略**開始指令。
- 斷線或取消訂閱時韌體會自己停止;新連接永遠唔會自動恢復掃描。未知指令會令韌體停止。

### 5.2 設定

```
CFG2:GET:<id>\n
CFG2:SET:<id>:<rawPower>:<idleSeconds>\n
```

例如 `CFG2:GET:42`、`CFG2:SET:43:20:10`。

- `rawPower` 10–26(讀卡器原始等級,**唔係實測 dBm**);`idleSeconds` 1–60,單位係**秒**(唔係毫秒)。
- App 用 ID 1–999(韌體接受 1–65535)。最長 `CFG2:SET:999:26:60\n` 係 19 bytes,放得入預設 20-byte payload。
- **GET**:停止讀卡器、讀實際參數、確認最後 STOP 後回覆。
- **SET**:停止讀卡器、讀取新鮮嘅 15-byte version 8 參數區塊、只改 byte 1(功率)、備份原有區塊、寫入一次再完整讀回驗證;秒數寫入 ESP32 NVS key `idle-seconds` 並讀回;最後 STOP ACK 先回 OK。功率冇變就唔寫讀卡器。兩部裝置嘅儲存**唔係原子操作**,任何失敗後都應該 GET 核對。
- 舊 `duration` NVS key 會被忽略;冇儲存 `idle-seconds` 就用 10 秒。App 唔會將舊時長數值搬過嚟。

## 6. App 行為(`BLE/ReaderSessionModel.swift`)

### 6.1 連接生命週期

1. App掃描廣播住 NUS service UUID 嘅裝置,使用者揀選並連接。
2. 連接只會喺 **RX 已找到而且 TX 訂閱經 `didUpdateNotificationStateFor` 確認** 之後先算就緒(徽章先顯示「已連接」)。所有 callback 都會核對 peripheral 身份同錯誤。
3. 就緒後 App 自動發一次 `CFG2:GET`;遇到開機期 `BUSY` 會最多再試 3 次(每次隔 1 秒)。App **永遠唔會自動 SET**。
4. 斷線、藍牙不可用、換裝置或訂閱失效時,清走 parser、pending ID、計時器、已確認設定同掃描狀態;舊 session 嘅回覆/callback 一律忽略。
5. 離開掃描畫面、App 入背景、中斷連接之前,盡力發 `MODE:IDLE`;之後唔會自動恢復。

### 6.2 設定

- 同一時間只有一個設定操作;SET 只喺使用者按「套用設定」時先發,**唔會自動重試**。
- 回覆要 ID 同連接 session 都吻合;GET 接受實際功率 0–33(例如 33 會照實顯示)、秒數 1–60;SET 回覆數值要同請求完全一致。
- 大約 8 秒冇回覆、錯誤、或者回覆數值唔一致:數值當未確認(SET 失敗會作廢已確認數值),提示使用者用 GET 核對。冇回覆唔代表冇寫入,App 唔會自動重發或者還原。
- 冇回覆時提示可能要更新至支援 CFG2 嘅韌體,或檢查讀卡器電源。讀卡器遲過 ESP32 通電時,可以喺畫面按「讀取設定」復原,唔使重開 App。

### 6.3 掃描狀態

- 「掃描」只喺:連接就緒、設定已確認、最近 3 秒內收到 `READY`、冇設定操作進行中時先可以按。重複按唔會發多個 MODE 指令。
- 發出 MODE 後顯示「正在啟動」直至見到 `SCANNING`。期間嘅 `READY` 可能係 preflight,唔當掃描完成;5 秒內未見 `SCANNING` 就盡力發 IDLE,並顯示「未能確認已開始掃描」。未見過 `SCANNING` 就返 `READY`,都唔會報成功。
- 見到 `SCANNING` 之後嘅 `READY` = 讀卡器已確認停止(包括韌體自動停止),按鈕回到「掃描」。**App 唔會因本地計時發 IDLE**,亦唔顯示倒數。
- 按「停止掃描」即時發 IDLE,顯示「正在停止…」,等 `READY`;6 秒內未確認就維持「未確認」。設定操作進行中都唔會停用「停止掃描」。
- `FAULT`:停用「掃描」,提示檢查讀卡器電源/接線,容許「停止掃描」同「讀取設定」復原。
- 掃描期間 3 秒收唔到 `@STATE`:顯示狀態未確認,並盡力發一次 IDLE;唔會當成已停止。

## 7. 已知限制(見方案書第9節)

- 冇配對(pairing)/加密要求,假設喺辦公室內部信任網絡環境使用。
- 單一手提機對單一App instance;若日後要支援多部手提機同時連接,需要擴充App嘅裝置管理邏輯。
- 功率數值係讀卡器原始等級,App 同韌體都冇量度 dBm、瓦數或溫度,亦唔能夠保證 RF 已經物理關閉;`FAULT` 時應關閉讀卡器電源。
- 標籤持續喺範圍內時冇總時長上限,唔好喺無人看管下長時間掃描。
