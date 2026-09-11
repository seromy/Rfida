# Rfida

RFID 器材出入管理系統 —— 攝影器材出入/盤點自動化,自行建置(DIY)方案。

完整背景、四大使用情景、系統架構、硬件清單同法規考量,見附帶嘅方案書。

## 本 Repo 內容

方案書入面嘅系統由硬件(YRM100 UHF讀寫模組 + ESP32)、韌體、iPhone App,到後台伺服器(Flask + SQLite)組成。本repo目前包含:

- **`ios/`** —— iPhone App(Swift、SwiftUI、CoreBluetooth),作為RFID手提機嘅「畫面」,涵蓋四大使用情景(錄入新標籤、出發前登記、返office前清點、定期盤點)。詳見 [`ios/README.md`](ios/README.md)。
- **`server/`** —— 後台伺服器(Flask + SQLite),提供App所需嘅REST API,以及一個Anthropic風格嘅網頁Dashboard,俾辦公室同事管理器材、員工、Job同查看出入/盤點紀錄。詳見 [`server/README.md`](server/README.md)。
- **`docs/`** —— App對外依賴嘅介面合約文件:
  - [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md):App同ESP32韌體之間嘅BLE(Nordic UART Service)通訊協議。
  - [`docs/API_CONTRACT.md`](docs/API_CONTRACT.md):App同Flask後台伺服器之間嘅REST API合約。

ESP32韌體本身未包含喺呢個repo,屬獨立開發組件,可依照 `docs/BLE_PROTOCOL.md` 對接。
