# Rfida 後台伺服器(Flask + SQLite)

RFID 器材出入管理系統嘅後台組件:提供 iPhone App 所需嘅 REST API(見 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md)),並附設一個網頁 Dashboard 俾辦公室同事用瀏覽器管理器材、員工、Job同查看出入/盤點紀錄。

網頁 Dashboard 視覺風格參考 Anthropic 官網嘅暖色系、留白、serif標題設計。

## 專案結構

```
server/
  run.py                    # 開發用啟動入口(flask run 或 python run.py)
  requirements.txt
  rfida_server/
    __init__.py             # App factory(create_app）
    extensions.py           # SQLAlchemy instance
    models.py                # Equipment / Staff / Job / Movement / InventorySession
    api.py                   # REST API blueprint(/api/*，對應 API_CONTRACT.md）
    dashboard.py             # 網頁 Dashboard blueprint
    seed.py                  # 示範資料
    templates/                # Jinja2 樣板(Dashboard 畫面)
    static/css/style.css      # Anthropic 風格樣式
```

## 安裝與啟動

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 首次啟動會自動喺 instance/rfida.sqlite 建立資料庫
python run.py
# 或者： FLASK_APP=run.py flask run

# (可選)灌入示範資料方便試用 Dashboard
FLASK_APP=run.py flask seed-demo
```

預設喺 `http://127.0.0.1:5000` 啟動：

- 網頁 Dashboard：`http://127.0.0.1:5000/`
- REST API base URL(俾 iPhone App「設定」畫面填):`http://<你部機IP>:5000`

## REST API

實作完全對齊 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md):

| 方法 | 路徑 | 用途 |
|---|---|---|
| GET | `/api/equipment` | 器材主檔清單 |
| GET | `/api/staff` | 員工清單 |
| GET | `/api/jobs?status=open` | Job清單(可用status篩選) |
| GET | `/api/jobs/{jobId}/expected-items` | 情景3專用:該Job出Job時帶走嘅器材 |
| POST | `/api/equipment/register` | 情景1專用:登記新EPC |
| POST | `/api/movements` | 情景2/3共用:提交出/入紀錄 |
| POST | `/api/inventory-sessions` | 情景4專用:提交盤點批次 |

## 網頁 Dashboard 頁面

- `/`:總覽(器材狀態統計、進行中Job、最近出入紀錄、遺失器材)
- `/equipment`:器材清單、搜尋/篩選、登記新器材、變更狀態
- `/jobs`、`/jobs/<id>`:Job清單、建立/結束Job、查看應有清單同出入紀錄(App假設Job CRUD由呢個Dashboard負責,見 API_CONTRACT.md「尚未涵蓋」一節)
- `/movements`:所有出入紀錄
- `/inventory-sessions`:所有盤點批次紀錄(標示未知EPC)
- `/staff`:員工名單管理

## 已知限制

- 冇登入/權限系統,對齊方案書第9節「信任網絡環境」假設,同 App 現時嘅實作一致。
- 用 SQLite,適合單一辦公室/單一伺服器部署;多分店同步未涵蓋。
