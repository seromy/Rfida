# iPhone App ↔ 後台伺服器 REST API 合約

呢份文件定義 iOS App(`ios/RfidaHandheld`)期望嘅 Flask + SQLite 後台REST API。後台伺服器本身唔喺呢個repo嘅範圍(方案書標註「已有雛型」,屬獨立組件),App已經按照呢個合約實作 networking layer(`Networking/APIClient.swift`),後台開發時請對齊,或者按實際情況調整App入面嘅路徑。

方案書4.2:「業務邏輯(員工名單、Job名單、commit紀錄)一律經WiFi打去後台伺服器。」BLE只負責傳送EPC,所有資料查詢/提交都經呢度嘅API。

Base URL 喺App「設定」畫面設定(例:`http://192.168.1.50:5000`),所有路徑都係相對呢個base URL。

## 通用約定

- 請求/回應body一律JSON,`Content-Type: application/json`。
- 日期時間用ISO 8601格式(例:`2026-09-11T10:30:00Z`)。
- 成功回應HTTP狀態碼 200-299;失敗時body建議帶plain text或JSON錯誤訊息,App會將body內容直接顯示俾使用者。

## GET /api/equipment

回傳器材主檔清單(對應「金屬器材標籤」「非金屬標籤」已登記嘅器材)。

```json
[
  {
    "id": 1,
    "epc": "E2801160600002042BB8A1C3",
    "name": "Sony A7IV 機身",
    "category": "機身",
    "serialNumber": "1234567",
    "status": "in_stock",
    "lastSeenAt": "2026-09-10T09:00:00Z"
  }
]
```

`status` 為 `in_stock` / `checked_out` / `missing` 其中之一。

## GET /api/staff

```json
[{ "id": 1, "name": "陳大文" }]
```

## GET /api/jobs?status=open

回傳進行中(未完成歸還)嘅Job清單。

```json
[{ "id": 10, "name": "2026-09-12 婚禮攝影", "date": "2026-09-12T00:00:00Z", "status": "open" }]
```

## GET /api/jobs/{jobId}/expected-items

**情景3(返office前清點)專用**:回傳呢個Job出Job時登記咗帶走嘅器材清單(即最近一次 `direction=out` 嘅movement紀錄入面嘅items),俾App做清單比對(方案書7.4)。

```json
[{ "epc": "E2801160600002042BB8A1C3", "equipmentId": 1 }]
```

## POST /api/equipment/register

**情景1(錄入新標籤)專用**:將EPC同器材資料配對登記。

請求:
```json
{ "epc": "E2801160600002042BB8A1C3", "name": "Sony A7IV 機身", "category": "機身", "serialNumber": "1234567" }
```

回應:新建立嘅 `Equipment` object(格式同 `GET /api/equipment` 入面嘅單一item)。

## POST /api/movements

**情景2(出發前登記)/ 情景3(返office前清點)共用**:提交出/入紀錄。

請求:
```json
{
  "jobId": 10,
  "staffId": 1,
  "direction": "out",
  "epcs": ["E2801160600002042BB8A1C3", "E2801160600002042BB8A1C4"],
  "missingEpcs": null,
  "note": null
}
```

- `direction`:`"out"`(出Job) 或 `"in"`(歸還)。
- `missingEpcs`:淨係喺 `direction="in"` 時有意義 —— App喺情景3自行比對「應有清單」同掃描結果之後,將缺件嘅EPC一併提交,後台可以用嚟更新器材狀態(例如標記為 `missing`)同記錄。

回應:200/201即可,body可為空或回傳建立咗嘅movement紀錄。

## POST /api/inventory-sessions

**情景4(定期盤點)專用**:提交一個盤點批次嘅結果。

請求:
```json
{
  "staffId": 1,
  "batchLabel": "A區",
  "scannedEpcs": ["E2801160600002042BB8A1C3"],
  "timestamp": "2026-09-11T10:30:00Z"
}
```

回應:200/201即可。後台可以自行將 `scannedEpcs` 對比器材主檔,計算未見/未知標籤。

## 尚未涵蓋(留返俾後台/日後擴充)

- 冇登入/權限系統(方案書第9節明確假設信任網絡環境),所以以上API都冇auth header。
- Job嘅建立/關閉(CRUD)未定義 —— 現時App假設Job清單由後台或其他管理介面維護,App淨係讀取 `status=open` 嘅Job。
- 多部手提機同時使用嘅中央同步架構(方案書第9節提及嘅擴展方向)未涵蓋。
