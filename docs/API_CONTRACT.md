# iPhone App ↔ 後台伺服器 REST API 合約

呢份文件定義 iOS App(`ios/RfidaHandheld`)期望嘅 Flask + SQLite 後台REST API。後台伺服器已按呢個合約實作喺 [`server/`](../server/)(見 [`server/README.md`](../server/README.md)),App已經按照呢個合約實作 networking layer(`Networking/APIClient.swift`)。如果實際實作有出入,對應調整 `server/` 或者App入面嘅路徑即可。

方案書4.2:「業務邏輯(公司名單、Job名單、commit紀錄)一律經WiFi打去後台伺服器。」BLE只負責傳送EPC,所有資料查詢/提交都經呢度嘅API。

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

## GET /api/company

```json
[{ "id": 1, "name": "陳大文攝影工作室" }]
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
  "companyId": 1,
  "direction": "out",
  "epcs": ["E2801160600002042BB8A1C3", "E2801160600002042BB8A1C4"],
  "missingEpcs": null,
  "note": null
}
```

- `direction`:`"out"`(出Job) 或 `"in"`(歸還)。
- `missingEpcs`:淨係喺 `direction="in"` 時有意義 —— App喺情景3自行比對「應有清單」同掃描結果之後,將缺件嘅EPC一併提交,後台可以用嚟更新器材狀態(例如標記為 `missing`)同記錄。

回應:200/201即可,body可為空或回傳建立咗嘅movement紀錄。伺服器回傳嘅 movement 另外帶 `unknownEpcs`(主檔未登記嘅EPC;App可以忽略)。

驗證:`jobId` / `companyId` 必須係存在嘅紀錄,`epcs` / `missingEpcs` 必須係字串陣列,否則回傳 `400` + `{"error": "..."}`。EPC 會被轉做大寫並去重;同一個EPC喺 `epcs` 同 `missingEpcs` 都出現時,以 `epcs`(已掃描)為準。
直接借出緊(有未完結借出單)嘅器材,返office時提交 `direction="in"` 唔會變返 `in_stock`,避免借出紀錄同庫存狀態矛盾。

## POST /api/inventory-sessions

**情景4(定期盤點)專用**:提交一個盤點批次嘅結果。

請求:
```json
{
  "companyId": 1,
  "batchLabel": "A區",
  "scannedEpcs": ["E2801160600002042BB8A1C3"],
  "timestamp": "2026-09-11T10:30:00Z"
}
```

回應:200/201即可。後台可以自行將 `scannedEpcs` 對比器材主檔,計算未見/未知標籤。

## 器材借出 API(後台網頁同日後客戶端使用,手提機 App 現時唔使用)

器材借出單(Loan)由網頁後台管理;以下 JSON API 提供同一套規則(`services.py`)俾其他客戶端使用。**器材 `status` 仍然只有 `in_stock` / `checked_out` / `missing`**:借出中嘅器材顯示為 `checked_out`,「借出中」由未完結嘅借出項目推算。

借出單物件:

```json
{
  "id": 1, "docNo": "LN-000001", "companyId": 3, "borrowerName": "黃美玲", "contact": "9345 6789",
  "purpose": "公司活動拍攝", "handledBy": "Peter",
  "loanDate": "2026-09-29T03:00:00Z", "dueDate": "2026-10-06",
  "status": "active", "isOverdue": true, "returnedAt": null, "note": "",
  "items": [{ "id": 1, "equipmentId": 4, "epc": "E2801160600002042BB8A1C4", "name": "Sony FE 70-200mm F2.8 GM",
              "state": "out", "returnedAt": null, "returnCondition": null, "returnNote": "" }]
}
```

`status`:`active`(借出中)/ `partial`(部分歸還)/ `returned`(已歸還)/ `cancelled`(已取消)。`isOverdue` 由 `dueDate`(辦公室本地日期)同未完結狀態推算。項目 `state`:`out` / `returned` / `cancelled`;`returnCondition`:`good` / `damaged` / `lost`。

| 方法 | 路徑 | 說明 |
|---|---|---|
| GET | `/api/loans?status=&equipmentId=` | 清單;`status` 可為 `active` / `partial` / `returned` / `cancelled` / `overdue` |
| GET | `/api/loans/{id}` | 單張借出單 |
| POST | `/api/loans` | 建立。body:`{"companyId"?, "borrowerName"?, "contact"?, "purpose"?, "handledBy"?, "dueDate": "YYYY-MM-DD", "loanDate"?, "note"?, "epcs": [...]}`。`companyId` 同 `borrowerName` 至少要有一個;`dueDate` 不可早過今日;所有 EPC 必須已登記而且可借出(在庫、冇損壞、冇借出),否則整張單唔建立。回傳 `201` |
| POST | `/api/loans/{id}/return` | 歸還。body:`{"returnAll": true}` 或 `{"items": [{"epc": "...", "condition": "good\|damaged\|lost", "note"?}]}` |
| POST | `/api/loans/{id}/extend` | `{"dueDate": "YYYY-MM-DD", "reason"?}`,只限未完結借出單 |
| POST | `/api/loans/{id}/cancel` | `{"reason"?}`,只限未有任何歸還嘅借出單 |

錯誤一律 `{"error": "..."}`:`400` 驗證失敗、`404` 找唔到、`409` 重複。

## 尚未涵蓋(留返俾後台/日後擴充)

- 冇登入/權限系統(方案書第9節明確假設信任網絡環境),所以以上API都冇auth header。(網頁表單另有CSRF保護;`/api/*` 唔使token。)
- Job嘅建立/關閉(CRUD)冇對外REST API —— App淨係讀取 `status=open` 嘅Job,Job清單改由 [`server/`](../server/) 嘅網頁Dashboard(`/jobs`)管理。
- 所有 `/api/*` 錯誤都係JSON(`{"error": "..."}`),包括找唔到嘅路徑同伺服器錯誤。
- 多部手提機同時使用嘅中央同步架構(方案書第9節提及嘅擴展方向)未涵蓋。
