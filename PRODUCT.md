# PRODUCT — UTUVO Type

> UTUVO Type 是目前 App 與產品線的顯示名稱。資料夾與 package slug 固定為
> `utuvo-type`；它是 UTUVO 小型工具系列中的文字／語音輸入工具。

## 一句話

把中文口述／選取內容即時整理成可直接貼上的繁體中文文本，本機優先、
雲端備援、deterministic 為骨、模型為皮。

## 目標使用者

- 慣用 macOS、每日大量中文書寫，需要穩定可預期的語音→文字排版品質
- 對雲端有顧慮，但願意在「明確需要」時呼叫雲端 formatter
- 願意自己控管 fallback、字典與提示詞

## M0 已完成；目前 vertical slice 已提供

- 原生 menu bar AppKit/SwiftUI UI
- 麥克風錄音、Qwen3-ASR 0.6B 本機 process、可選 on-device speech fallback
- 百鍊 qwen-audio-3.0-asr-flash-streaming WebSocket adapter（partial transcript）
- 百鍊 OpenAI-compatible streaming formatter（content-only）
- Fast / Smart / Edit Selection / Deep 的 routing、貼上與取消狀態
- AX 只讀 foreground bundle、focused field role、bounded selected text；不讀整個螢幕

## 尚未宣告的部分

- **不**宣告真實 latency、P50/P95 或 provider 品質數字；P2–P5 必須用實際帳號／本機 runtime 跑完 benchmark 才能填入。
- 本機 Qwen3-ASR 0.6B 與 Qwen3 4B editor 由產品自己的 runtime wrapper
  提供；模型權重放在被 Git 忽略的 .models/，不進 repo，也不修改其他 App 或系統上的 Ollama。App 不會自動下載 27B。

## 產品承諾

1. **本機永遠可用**：雲端失敗、逾時、不支援模型時，
   必須退回 deterministic 輸出，**不再錄第二次**。
2. **原始 transcript 留底**：排版結果旁永遠保留 raw transcript，
   之後可手動覆寫。
3. **預設不思考**：`enable_thinking=false`、temperature ≈ 0、
   bounded output、content-only parsing。
4. **小輸入不上大模型**：一句話以內的短輸入絕對不走 27B／plus／max。
5. **不寫秘密**：本 repo 不放任何 API key、token、webhook URL。

## 模式

| Mode | 觸發 | 預設路徑 | 備註 |
|---|---|---|---|
| Fast | 短句、低延遲需求 | 本機 ASR + deterministic | 不進任何 LLM；目前預設 |
| Smart | 一般口述 | 選定 backend 的 flash／小型 local editor | 不進 plus/max/27B，除非明確 Deep |
| Edit Selection | 對已選取文字做改寫 | qwen3.7-flash；長／高品質 → opt-in qwen3.7-plus | |
| Deep | 長文、會議紀錄、需要結構化 | opt-in qwen3.7-plus；本機 27B 為 adapter（不自動下載） | 從不預設 |

## 評量

詳見 `benchmarks/README.md`。本里程碑**只**對 deterministic 路徑產生
有意義數字；雲端／27B 路徑只標示「待 configured provider 跑過後填入」。
