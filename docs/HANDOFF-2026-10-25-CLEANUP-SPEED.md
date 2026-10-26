# 整理請求前的詞庫準備加速

Micky要求繼續減少整理等待，保留Kordan設定。Phone工具與手機操作仍暫停，產品效能工作繼續。

- `VocabularyCatalog.swift`：排序時快取每個命中詞的Character長度，避免比較器重複計算；本句拉丁token集合為空時略過必為零的交集計算。
- 完整掃描、排序、詞庫內容與順序、個人詞／站名規則、50／200上限都保留。SmartCleanup、KeyboardVoiceHost、模型／提示詞／timeout／品質把關／fallback／一次交付未改。
- 隔離iOS模擬器72項相關測試通過；原版／新版1,680項差分檢查、195對量測輸出與順序相同。新建模擬器已清除。
- Mac Release重型六包詞庫案例，選詞p50約254→155ms、長段208→141ms；小詞庫差異小，p95有波動。不能推成手機或Claude整段加速比例。

本輪未做手機／雲端請求、公開repo同步或發版。完整前後數字、較慢樣本與限制在workspace的`tasks/type-cleanup-speed-check-2026-10-24/RESULT-2026-10-25.md`及JSON原始結果。尚缺真機端到端效果，不能稱整體速度問題已結案。
