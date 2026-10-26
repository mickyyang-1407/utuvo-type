# 自動條列修復（2026-10-24）

- iOS 一般文字欄位的 Return=send/done/next/continue 不再自動被當成單行；明確搜尋／網址／電子郵件／電話／數字類欄位仍採單行輸出。兩個鍵盤交付入口使用同一規則。
- Swift / Android Core 對明確連續的 1..N 行內清單做保真換行；不猜清單項目，不轉小數／版本／非連續編號／code。移動編號位置以保留最後一項前的「還有最重要的」等連接語。
- 內容把關只在來源與輸出項數相同、輸出編號連續時對齊結構編號；項目內容、真實數值與否定照舊驗證。沒有全面放寬 gate。
- 三平台普通聽寫的候選與退回原文都尊重 autoList；模型失敗時仍能排版原文已明確編號的清單。iOS / Mac 有 production 入口退回測試，Android service 用同一 shared helper；未把 mock/unit 等同真機宿主驗收。

驗證：Swift Core既有69例＋新增SwiftTesting4函式（13情境）；Mac Delivery/Cleanup65例；iOS模擬器既有77例＋新增SwiftTesting2函式（3情境）；Android Core412/App302與debug APK全通過。初次Kotlin測試import修為專案使用的kotlin.test後通過。專案檔只保留新增測試接線與build號，移除xcodegen帶來的資源群組名稱變動。

iOS build37用於TestFlight重測，商店審查仍綁build36。本機封存／上傳／VALID／內部群組／IN_BETA_TESTING為各自獨立檢查，實際狀態與完整證據見工作區 `tasks/type-autolist-fix-2026-10-24/RESULT.md`。尚未代表真機ASR、第三方宿主或新商店版已驗收。Mac/Android本輪只同步原始碼，沒有新正式下載包。
