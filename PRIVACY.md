# PRIVACY — UTUVO Type

> 本機 deterministic 路徑不聯網；百鍊是明確可切換的選項。App 不寫秘密，
> 不收集截圖，且不保存完整螢幕內容。

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
