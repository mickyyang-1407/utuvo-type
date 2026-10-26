# Claude整理等待改善 — build 39

依Micky要求保留Kordan設定，縮短整理前的準備，並交付0.3.2(39)供TestFlight實測。

- `SmartCleanup`的本機completion改成lazy求值；Claude成功時不先查Apple／Gemma readiness，雲端失敗才解析本機退路。enabled檢查也先判斷已配置的雲端條件，布林結果不變。
- 錄音開始時的既有warmUp增加已啟用bundle詞庫的背景預載，沿用原loader cache；不預送逐字稿、不增加模型請求、不改偏好。最終選詞仍取當時的啟用詞庫與個人字典。
- 納入前輪已驗證的選詞排序字長快取與空拉丁集合優化；詞庫內容、選詞分數與順序、每包50／總200上限保留。

Claude provider／model／endpoint、提示詞文字、thinking／temperature、timeout、autoList、品質把關、cloud→local fallback順序與一次final交付均保留。辨識、鍵盤路由與交付程式未修改。

驗證：相關iOS四suite共76項通過；原版在「Claude成功不查本機readiness」新增測試確實失敗，新版通過。實際bundle loader fixture證明只預載啟用包、關閉包未載、偏好未改、停止後使用既有快取。前輪1,680差分與195對選詞順序證據保留。

Mac Release六包全開的冷載入情境，停止後準備中位約846→126ms；另約715ms工作提前到錄音期間，沒有消失。這是本機壓力情境，並非Claude生成或實體iPhone改善數字；錄音太短、詞庫未開或快取已暖時不保證同等收益。

沒有重啟Phone工具、操作手機或跑Azure；未改正式商店綁定。TestFlight可用性以workspace `tasks/type-claude-speed-2026-10-26/`的Apple讀回為準，實際按停止到貼字時間與品質由Micky更新後驗收。
