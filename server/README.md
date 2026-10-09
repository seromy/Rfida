# Rfida 後台伺服器(Flask + SQLite)

RFID 器材出入管理系統嘅後台組件:

- 提供 iPhone 手提機 App 所需嘅 REST API(見 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md));
- 附設一個 **SAP Fiori 風格**嘅網頁後台,俾辦公室同事用瀏覽器管理器材主檔、公司、Job、**器材借出服務**,同查看出入 / 盤點紀錄同變更紀錄。

## 專案結構

```
server/
  run.py                      # 開發用啟動入口(python run.py)
  pyproject.toml / requirements*.txt
  tests/                      # pytest(API 合約、借出規則、網頁頁面、舊資料庫升級)
  rfida_server/
    __init__.py               # App factory:設定、CSRF、安全 header、樣板 filter、錯誤頁
    extensions.py             # SQLAlchemy instance
    models.py                 # Equipment / Company / Job / Movement / InventorySession / Loan / LoanItem / AuditLog
    services.py               # 所有狀態轉換規則(API 同網頁共用),並寫入變更紀錄
    schema.py                 # 舊資料庫原地升級(補欄位、清理孤兒參照)
    utils.py                  # 時區、EPC 正規化、CSV 防公式注入等
    api.py                    # REST API blueprint(/api/*)
    dashboard/                # 網頁後台:每個業務對象一個模組
    seed.py                   # 示範資料
    templates/                # Jinja2:base(Shell bar + 側邊導覽)、_components(共用元件)、dashboard/*
    static/css/style.css      # Fiori Horizon 風格樣式
    static/js/app.js          # 漸進增強(側邊導覽、分頁籤、確認對話框、器材選擇器)
```

## 安裝與啟動

```bash
cd server
uv sync            # 或:python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt
python run.py      # 預設 0.0.0.0:8123,首次啟動會自動建立 instance/rfida.sqlite

# (可選)灌入示範資料(器材、公司、Job、借出單)
FLASK_APP=run.py flask seed-demo

# 跑測試
python -m pytest
```

- 網頁後台:`http://127.0.0.1:8123/`
- REST API base URL(俾 iPhone App「設定」畫面填):`http://<你部機IP>:8123`

環境變數:

| 變數 | 預設 | 用途 |
|---|---|---|
| `PORT` / `HOST` | `8123` / `0.0.0.0` | 監聽位址(手提機經 Wi-Fi 連入,所以預設係 `0.0.0.0`) |
| `DATABASE_URL` | `sqlite:///instance/rfida.sqlite` | 資料庫 |
| `APP_TIMEZONE` | `Asia/Hong_Kong` | 網頁顯示時區(資料庫一律存 UTC) |
| `SECRET_KEY` | 自動產生並存喺 `instance/secret_key` | Session / CSRF 簽署 |
| `FLASK_DEBUG` | 關 | `1` 先開 Werkzeug debugger(可遠端執行程式碼,**唔好喺公司網絡開**) |

舊版本資料庫會喺啟動時自動升級(補欄位、EPC 轉大寫、清理已刪除公司留低嘅孤兒參照)。

## 網頁後台

Shell bar(全域搜尋:可直接輸入單號例如 `LN-000012` 或完整 EPC 跳轉,按 `/` 聚焦)+ 側邊導覽:

| 區 | 頁面 | 說明 |
|---|---|---|
| 首頁 | `/` | Launchpad:器材狀況 / 借出服務磚、逾期借出、三日內到期、遺失、損壞、最近活動 |
| 主檔 | `/equipment` | 器材清單(搜尋、分類 / 位置 / 狀態篩選、排序、分頁、匯出 CSV、批量「借出所選」)、object page(一般資料 / 借出紀錄 / 出入紀錄 / 變更紀錄)、登記、編輯、狀態與損壞管理 |
| 主檔 | `/company` | 公司(聯絡人、電話、電郵)清單與 object page(借出單 / 出入 / 盤點) |
| 作業 | `/loans` | **借出單**(見下) |
| 作業 | `/jobs` | Job 清單、建立 / 編輯 / 結束 / 刪除、出 Job 應有清單 |
| 作業 | `/movements` | 手提機出入單據(篩選、匯出 CSV、單據明細) |
| 作業 | `/inventory-sessions` | 盤點批次;未知標籤可一鍵登記 |
| 報表 | `/reports/stock` | 庫存概覽(按分類統計,匯出 CSV) |
| 報表 | `/reports/changes` | 變更紀錄(全域變更文件) |

每個業務對象都有單號(`EQ-` 器材、`CO-` 公司、`JB-` Job、`MV-` 出入、`IV-` 盤點、`LN-` 借出單)、list report、object page 同變更紀錄。

### 器材借出服務

1. **新增借出單**(`/loans/new`):揀公司或填借用人、到期日、用途、經手人;喺可篩選嘅清單揀器材,或者貼上手提機掃描嘅 EPC 清單。只有「在庫、冇損壞、冇借出」嘅器材可以借出。
2. **借出中**:器材狀態變成 `checked_out`(對手提機 API 保持兼容),網頁顯示為「借出中」並連結返借出單。
3. **到期跟進**:到期日一過,借出單自動標示「已逾期 N 日」,出現喺側邊導覽徽章、首頁同 `/loans?status=overdue`。
4. **歸還**:逐件或全部歸還,每件可標記 正常 / 損壞 / 遺失。損壞 → 器材回庫但標記「損壞待修」(修復前唔可再借);遺失 → 器材標記遺失。全部歸還後借出單自動完結。
5. **延期**(記錄原因)、**取消**(只限未有任何歸還)、**列印借用單**(`/loans/<id>/print`,附簽署欄)。

借出單同樣有 JSON API:見 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md) 「器材借出 API」。

## 已知限制

- 冇登入 / 權限系統,對齊方案書第 9 節「信任網絡環境」假設;網頁表單有 CSRF 保護,但任何可連到伺服器嘅人都可以操作。
- 用 SQLite,適合單一辦公室 / 單一伺服器部署;多分店同步未涵蓋。
- 「經手人」係自由文字,因為冇用戶系統。
