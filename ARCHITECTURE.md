# ARCHITECTURE — UTUVO Type

## 模組邊界

```
Sources/
├── UTUVOTypeCore/          # 純函式核心（無 IO、無 SDK 依賴）
│   ├── Normalizer          # 標點、贅詞、重複片段、自修正、數字／日期／金額、字典、清單
│   ├── Routing             # 模式路由、模型 fallback、短句禁大模型、plus-only 條件
│   ├── PromptLoader        # 讀 prompts/formatter-v1.txt 並安全填入 placeholder
│   ├── ASRClient           # backend A/B 的 streaming ASR protocol contract
│   ├── Context             # limited app context contract（不讀螢幕）
│   └── Fixtures            # 載入 benchmarks/cases.jsonl
├── UTUVOTypeApp/            # 原生 menu bar App
│   ├── AppModel             # 四模式 orchestration、fallback、paste payload
│   ├── AudioCapture         # AVAudioEngine、16 kHz mono PCM、暫存音訊
│   ├── AudioDevices         # CoreAudio 輸入／輸出端點與輸入聲道選擇
│   ├── FeedbackTonePlayer   # 可選的短提示音與輸出端點路由
│   ├── Providers            # Bailian WebSocket/SSE、local ASR/editor/Ollama adapters
│   ├── AccessibilitySupport # focused app/selection 的最小 AX 讀取
│   └── UTUVOTypeApp         # status item、menu、settings window、global hotkey
└── UTUVOBench/              # benchmark 執行檔（命令列）
    └── main.swift
Tests/
└── UTUVOTypeCoreTests/     # XCTest：normalizer、routing、prompt、fixtures、衛生
prompts/
└── formatter-v1.txt
config/
├── routing.example.json
└── dictionary.example.json
benchmarks/
├── cases.jsonl             # 30 題
└── README.md
scripts/
├── verify-scaffold.sh
└── run-benchmark.sh
```

## Deterministic 與 LLM 的接縫

- **Deterministic core**：永遠先跑。輸出 = `NormalizedText`。
  任何錄音／輸入進來的第一關都是它。
- **LLM formatter（adapter contract）**：`FormatterClient` protocol。
  百鍊 formatter 使用 `stream=true`，只累積 `choices[].delta.content`；
  `reasoning_content` 永遠不進 paste payload。雲端錯誤／逾時／不可用時
  → 退回 `NormalizedText`，**不重錄**。
- **本機 27B**：`LocalDeepFormatter` 由 Ollama HTTP adapter 提供，只有
  使用者手動填入 model 且進入 Deep 才會呼叫；不自動下載、不改 Ollama 設定。
- **ASR backend A**：`BailianASRTranscriber` 走官方 duplex WebSocket
  `run-task → task-started → binary PCM → finish-task`，把 sentence partial
  送回 menu status。
- **ASR backend B**：優先執行使用者設定的本機 Qwen3-ASR 0.6B command；
  現成 wrapper 在 runtime/utuvo-type-asr，於 127.0.0.1:18765
  維持 mlx_audio.server warm；沒有 command 時才嘗試 macOS on-device
  fallback。

### 本機小型 editor

LocalFormatterProcessClient 將 formatter prompt 經 stdin 送給
runtime/utuvo-type-editor.py。wrapper 在 127.0.0.1:18766 啟動
mlx_lm.server，使用 Qwen3 4B 4-bit；只在 Smart／Edit／需要時呼叫，
Fast 永遠跳過。editor 失敗時退回 deterministic。

## Routing 規則（摘要）

1. 計算輸入特徵：長度、是否包含清單線索、是否包含自修正、
   是否包含字典詞彙、是否在選取模式下、是否包含 Markdown 結構。
2. `shortSentence(input) = (trimmed length ≤ 12 中文／字混合計）and (無清單／無自修正／無 Markdown)`
   → 短句**永遠**不走 plus／max／27B。
3. `Edit Selection`：含 `<selected>` 區塊；長度 > 80 或高品質 flag →
   允許 plus；其他一律 flash。
4. Smart／Edit Selection 超過設定的字數或音訊門檻才可升 plus；
   一句短句即使音訊很長也不升級。
5. `Deep`：明確 deep flag 或會議紀錄類別（meeting-notes） →
   允許 plus；27B 為 opt-in adapter，不自動下載。
6. `Fast`：無論長短都只走本機 ASR + deterministic，formatter 路徑略過。

完整規則見 `Tests/UTUVOTypeCoreTests/RoutingPolicyTests.swift`。

## Adapter contract

```swift
public protocol FormatterClient: Sendable {
    func format(prompt: String, model: String) async throws -> String
}

public protocol LocalDeepFormatter: Sendable {
    func format(_ text: String) async throws -> String  // 27B 等
}
```

實作目前直接住在 `Sources/UTUVOTypeApp/Providers.swift`，仍透過上述
protocol 與核心分離；不會把 provider decision 藏進 normalizer。

## 不在這層

- 其他 App 的設定與資料
- .models/ 內的本機模型權重、.runtime/ 內的 Python runtime、Ollama 設定
- 百鍊 API key、webhook URL
- 任何客戶資料／個資／憑證

## 設計取捨

- **Swift 6.3 / SwiftPM**：和 Pik 其餘 macOS 產品棧一致；
  Swift concurrency（`async`／`Sendable`）原生支援，避免引進額外 runtime。
- **核心 0 依賴**：normalizer / routing / fixtures 不依賴任何
  第三方套件；測試與 benchmark 不引入 SwiftPM dependency。
- **AppKit/SwiftUI 只在 app target**：UI、權限與 live 串接不反向污染
  deterministic core；核心仍可獨立測試與 benchmark。

## 失敗策略

| 失敗 | 行為 |
|---|---|
| 雲端 formatter 拋錯 | 退回 deterministic 結果；保留 raw transcript |
| 雲端 formatter 逾時 | 同上；timeout 計入 timeout rate |
| 雲端模型不在 fallback 鏈 | 同上；記 fallback success = false |
| 本機 27B 未載入 | Deep mode 退回 plus；不自動下載 |
| Prompts 檔案讀不到 | 雲端路徑降級為 deterministic |
| Fixtures 載入失敗 | verify-scaffold 失敗、exit ≠ 0 |
