# PRIVACY — UTUVO Type

> 本機 deterministic 路徑不聯網；百鍊是明確可切換的選項。App 不寫秘密，
> 不收集截圖，且不保存完整螢幕內容。

## iOS 原始碼分支的資料流（尚待發布）

本節說明本分支新的 iOS 本機／雲端模式；下方里程碑與 macOS 的歷史說明不應當成 iOS 的現行路由規則。

- **本機模式**：音訊與待整理文字不送到辨識／整理服務；鍵盤透過主 App 的背景語音工作階段使用裝置端辨識與可用本機模型。
- **雲端模式**：錄音只在已授權雲端辨識時送到選定 ASR 服務；待整理文字與選取的詞彙提示送到選定文字服務。兩個服務可分開選，不會自動改用其他已存 key。
- **舊設定遷移**：只儲存文字整理 key 不會自動取得錄音上傳授權；原本只用裝置端的選擇保留。
- **欄位脈絡**：預設關閉。開啟後最多提供游標前 500 字、後 200 字與有上限的欄位提示；密碼等敏感欄位由既有欄位保護規則排除。不讀取螢幕截圖，也不宣稱取得 iOS 宿主 App 名稱。
- **儲存**：key 使用共用 Keychain；歷史依使用者保留設定保存原始辨識與最終輸出。診斷保存階段、服務、時間、字數與結果，不保存逐字稿內容或 key。既有 iCloud 字典同步是獨立功能。

操作方式見 [iOS 使用者手冊](docs/USER-GUIDE-iOS.md)，實作與驗證限制見 [路由說明](docs/IOS-DICTATION-ROUTING.md)。

## 本里程碑（M0）的現實

- **離線可用**：核心、測試、benchmark 與 Fast 整理全部可離線跑；
  只有百鍊 backend 會送出明確選定的音訊／prompt。
- **不寫秘密**：`config/*.example.json` 只能放結構示範；
  真實 `config/routing.json` 由 M2 之後在使用者的機器上手動建立，
  永遠**不**進 git。
- **不收集截圖**：M1 之後即使做「應用上下文」，也只取 foreground bundle id、
  focused field token、selected text、bounded surrounding context
  （明確需要時才開）。

## 未來會接觸的個資邊界

| 資料 | 用途 | 預設 |
|---|---|---|
| 語音 PCM | ASR 輸入 | 記憶體串流；為本機 process 需要時短暫寫入 session CAF，完成後刪除 |
| ASR transcript | 排版輸入 | 保留為 raw fallback；M3 才考慮落地 |
| 應用 bundle id | 路由 / 字典切換 | 記憶體內 limited context |
| 選取文字 | Edit Selection 模式 | bounded、記憶體，不讀整個 field/螢幕 |
| 字典 | 個人詞彙 | 使用者檔案，雲端 formatter 預設不夾帶個資 |
| 視窗標題、網頁網域＋路徑（不含查詢參數與帳密）、欄位提示文字 | 整理時判斷語氣與格式（2026-10-13） | 跟「附帶有限的周邊 context」同一個開關，預設關；有長度上限；設定裡列出的網站（預設含密碼管理器、登入、付款頁）完全不送，只留 App 名稱 |
| 貼上後那段文字的修改 | 「從你的修改學字典」：只在本機比對，留下「原字→改後」短詞當建議（2026-10-13） | 預設開、可關；欄位文字不保存、不送出；大幅改寫不學；密碼欄不讀 |
| 使用數據 | 設定 →「使用數據」頁：字數、說話秒數、次數（每天一筆）（2026-10-13） | 只存數字、不存文字，只在這台 Mac |
| Ask anything 的問題與選取文字 | 送到使用者自己設定的整理服務（Groq／Gemini／百鍊／自訂）取得回答或改寫（2026-10-13） | 只在按下 Ask anything 快捷鍵時送；選取文字有 12,000 字上限 |

## 雲端 formatter 的邊界

- 預設 `qwen3.7-flash`，`enable_thinking=false`、`stream=true`、
  temperature ≈ 0、bounded output、content-only parsing。
- 提示詞明確禁止 reasoning content、hallucinated facts、JSON、
  code fences、`<think>`。
- fallback：`qwen3.7-flash → qwen3.6-flash → qwen3.5-flash`。
- `qwen3.7-plus` 為 opt-in（高品質／長／deep）；從不自動升級。
- `qwen3.7-max` 不在普通口述範圍。

## 不可做的事

- 把任何 API key、token、webhook URL commit 到任何 repo
- 把客戶資料／個資／未公開母帶送進雲端 formatter
- 在使用者不知情時自動下載模型權重
- 用「聽起來合理」的方式填 latency／準確率數字

## 事故處理

一旦發現任何 commit 內含秘密或個資：

1. 立刻停 push
2. 用 `git filter-repo` 或 BFG 清掉歷史
3. 撤銷／rotate 對應 key
4. 在 repo issue 補一筆 audit log
