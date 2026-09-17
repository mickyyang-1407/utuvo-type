# Benchmarks — UTUVO Type

> 本檔只描述評估路徑與量測項目；**不**在本里程碑填入實際數字。
> 任何 latency / 準確率必須在「fixtures + configured provider」跑過後
> 才填入，沒跑過就標 `pending`。

## 五條評估路徑

| 路徑 | ASR | Formatter | 適用 |
|---|---|---|---|
| P1 | 本機 ASR | deterministic normalizer | 短句、選取編輯、低延遲 |
| P2 | 百鍊串流 ASR | qwen3.7-flash | 一般口述預設 |
| P3 | （沿用 P2 ASR） | qwen3.7-flash fallback（qwen3.6-flash → qwen3.5-flash） | P2 失敗時降級 |
| P4 | 本機 ASR | 本機小型 editor（adapter） | 無網路／隱私場景 |
| P5 | 本機 ASR | 本機 27B Deep | Deep mode opt-in |

> 本里程碑（M0）**只**對 P1（deterministic 路徑）有意義數字。
> P2–P5 在 fixtures + configured provider 跑過之前全部標 `pending`。

## 量測項目

| 項目 | 定義 | 適用路徑 |
|---|---|---|
| ASR first-token latency | ASR 開始送出到第一個 token 出現的時間 | P1, P2, P4, P5 |
| Stop-to-paste latency | 使用者停止錄音到貼上完成的時間 | All |
| P50 / P95 | latency 的百分位數 | All |
| List accuracy | 清單線索被偵測且正確分行／編號的比例 | P1, P2, P3, P4 |
| Meaning preservation | normalized 與原文核心語意是否一致（人工抽樣） | All |
| Hallucination rate | 雲端 formatter 捏造原文沒有的內容的比例 | P2, P3, P5 |
| Traditional Chinese accuracy | 標點、用字是否維持繁體中文 | All |
| Timeout rate | 雲端 formatter 逾時的比率 | P2, P3, P5 |
| Fallback success rate | 從 primary 降級到 fallback 鏈後成功的比率 | P2, P3 |

## 報告產出

```bash
./scripts/run-benchmark.sh
# 產出 benchmarks/report.json：
# {
#   "schema_version": "0.1.0",
#   "timestamp": "...",
#   "fixtureCount": 30,
#   "byPath": { "P1": { "samples": [...], "summary": {...} } },
#   "pendingPaths": ["P2", "P3", "P4", "P5"]
# }
```

`byPath.P1.summary` 在 M0 內部產出；P2–P5 在 M2 / M3 之前
固定列在 `pendingPaths`，不得填入任何假造的數字。

## Fixture 設計

`cases.jsonl` 共 30 題，10 個 category 各 3 題：

| Category | 用途 |
|---|---|
| short-dictation | 短句、走 Fast／Smart 短句禁大模型規則 |
| mixed-zh-en | 中英混合、英文術語保留 |
| proper-noun | 專有名詞正確性 |
| self-correction | 「不是 A，是 B」「A 不對 B」 |
| list-cue | 第一／第二／首先／接下來分行 |
| todo | 待辦清單線索 |
| long-paragraph | 長段落保留 |
| meeting-notes | 日期／時間／金額數字正規化 |
| selection-edit | `<selected>...</selected>` 區塊保留 |
| markdown | Markdown 結構保留 |

每題必含 `id` / `category` / `transcript` / `expected` / `assertions`。
任何缺漏都會在 verify-scaffold 階段擋下。

## 衛生檢查

`scripts/verify-scaffold.sh` 內部跑：

- `cases.jsonl` 必須恰好 30 行
- 必須覆蓋全部 10 個 category、每個 category 至少 3 題
- 沒有空 `id`／`category`／`transcript`／`expected`
- 沒有 `<think>`／`JSON`／` ``` ` 之類的 forbidden 輸出痕跡
- source tree 沒有 secret-like literal

## 不准做的事

- 假造 latency / 準確率數字
- 在 P2–P5 還沒實測前把它們從 `pending` 升成數字
- 把任何 fixture 內含的真實客戶資料／個資 commit 進 repo
