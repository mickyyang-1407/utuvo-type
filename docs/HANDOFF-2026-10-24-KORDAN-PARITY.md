# Mac / Android：Kordan 一次交付契約

這輪同步 Mac / Android 原始碼；未簽署或發布新的正式安裝版。提交、遠端讀回與驗證證據見任務資料夾 RESULT.md。iOS build 36、既有共享 Core 與昨日 FX11–13 規則未修改。實驗語料與音訊、私人歷史、API keys 沒有送往任何 provider。

## 行為

- 普通 Smart dictation：辨識 → 有時限的整理 → 詞彙感知共同把關 → 一次插入最終文字。直接聽寫、翻譯、Ask/Edit 的用途維持原有。
- Mac 沿用現有獨立 ASR / cleanup provider 設定，不新增兩模式全域開關；雲端等待最多 6 秒，本機 formatter 另有 4 秒預算。失敗交付 deterministic 結果。取消使舊 callback 作廢。
- Mac 同時捕獲 AX 與獨立 clipboard 目的地。AX 無落地時不重跑模型；確認原 app、field、range、附近文字仍一致，且沒有晚到的 AX 文字，才送出一次 clipboard paste。無法安全核對就保留歷史/結果卡供複製。
- Android 沿用已選 provider / key 與現有 on-device readiness。雲端失敗後只嘗試已準備好的手機模型，各自使用既有 cloud/local deadline。兩者失敗仍插入 deterministic 文字。普通聽寫一次 `commitText(prefix + final)`；VoiceTurns、接續前綴與 undo 都在最終結果上記帳。
- Android 整理 pending 時再按 mic 暫不啟動新錄音，保留前一句；完成或明確按 ✕ 後才可再次開始。換輸入框、connection、游標附近內容或取消後不貼舊結果。未送達結果寫歷史供恢復，不計入已交付 usage。
- 同一 provider、variant、字典、詞庫與目標在整理開始時固定。所有 provider 使用共同 fidelity gate；核准近似英文專名先正規化，再驗證數字/否定/內容。保留「三樓不是四樓」「48K不是96K」對比與中文詞典邊界，沒有複製 iOS 原版已知錯誤。

## 診斷的證據邊界

`candidate-ready` 只表示候選已取得；`local-fallback` 表示走獨立本機嘗試；`skipped-target-changed` 不表示送達。Mac AX 的 `delivered` 有現行 AX readback；Mac clipboard 與 Android `InputConnection.commitText` 成功只記 `insertion-api-accepted`，無法證明宿主實際顯示或接收。新增診斷只有 turn / generation / provider / outcome，不記逐字稿或 keys。

## 驗證

最終驗證：Mac App 355 項，2 項硬體 opt-in skip、0 failure；Swift shared Fidelity/Normalizer 107 通過；Android Core 409、App 302 項全通過，debug APK 編譯通過。獨立 MiniMax delta review PASS。

Logs 與完整結果在 `tasks/type-kordan-mac-android-2026-10-24/REPORT.md`。所有測試使用隔離 UserDefaults/storage、mock transport 或純 callback fixture；未操作日常裝置、真實 ASR、本機模型或 live provider。

異來源 MiniMax 靜態 review 初輪找出兩項問題，修復後 delta review PASS：Android 重入 start 保留原 pending turn；Mac clipboard throw 正確分類為貼上失敗。Mac 有限 readback 等待之後仍可能遇宿主 AX 極晚落地競爭，尚未用實機量測。Chrome/Claude 桌面實際貼入、Android IME host 與本機模型延遲仍需實機驗收；編譯與 mock 測試不能代替這些證據。
