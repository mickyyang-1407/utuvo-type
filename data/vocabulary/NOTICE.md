# NOTICE — UTUVO Type 詞庫（type-vocabulary catalog）

資料重建日期：2026-09-20
schemaVersion：2（catalog.json；metadata 與 terms 分檔）

本目錄含六包：`computing`、`medicine`、`finance`、`law`、`engineering`、`music`。
每包由兩個檔案組成：

- `catalog.json` 中的 `<id>` 條目：metadata（指向 termsFile 與其 sha256）
- `<id>.txt`：UTF-8、LF、一行一詞、尾 LF；該包的實際詞表

## 授權（CONTRACT-V2：不可冒稱 OGDL）

六包的資料源都是國家教育研究院 樂詞網（https://terms.naer.edu.tw/）下載專區的 zip 壓縮檔。
這些資料集**沒有**出現在 data.gov.tw / data.nat.gov.tw / TAIC 等開放資料平台（已實證搜尋無命中），
授權依據為樂詞網站自身的「政府網站資料開放宣告」：

- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/

宣告重點（curl 取得後節錄）：
> 為利各界廣為利用網站資料…以無償、非專屬、得再授權之方式提供公眾使用，使用者得不限時間及地域，
> 重製、改作、編輯、公開傳輸或為其他方式之利用…使用時，應註明出處。

並非 OGDL-Taiwan-1.0（雖然精神相近，但 OGDL 是另一份由國家發展委員會（NDC）維運的通用授權文件）。

## 清洗規則（termsFile 產生流程）

1. 從每個 zip 取所有內含的 ODS，解析 `<table:table-row>`。
2. 以表頭識別『中文名稱』／『中文名詞』欄。
3. 對每個 cell 文字：
   - 先 unescape HTML entity；去 `<...>` 標籤；移除 ASCII 控制字元；合併連續空白
   - 移除 `〈〉《》` 夾註
4. 以 `;` ／ `,` ／ `；` ／ `，` 拆分同義詞並列（depth-aware：括號內不切）
5. 詞首有 `﹝電磁﹞` 這類分類括號時剝掉該對，留下主詞
6. 去除括號內解釋（如 `紅斑（紫外放射光）` → `紅斑`）
7. 拒絕規則（CONTRACT-V2）：
   - 半形括號 / 方括號 / 大括號左右不平衡的破壞片段
   - 詞首數字或英文字母後接 `)` 的編號彙片（`7) 碼`、`b) 樹` 這類）
   - 含 `=`, `∑`, `∫` 等數學運算子的公式片段
   - 短副檔名前綴（`.AFM`、`.3GR`）視為格式標籤，不列入詞庫
8. 跳過純英數、長度 <2 或 >40 的詞目
9. 同包內全部 zip 合併後去重（保序）；輸出至 `<id>.txt`
10. seedTerms 由 curated 清單中挑 20–40 個本包**確實存在**的日常專業術語（非等距抽樣）

## 各包來源與顯名

### 資訊與電腦 (`computing`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。詞目取自「電子計算機名詞」資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 電子計算機名詞壓縮檔_cTrpXtC.zip | `88e8e269695f4af9bb61a120a57575ea52f1136136322d9efffb0770ee376c8c` | 14 | 133982 | https://terms.naer.edu.tw/media/terms_data/1/電子計算機名詞壓縮檔_cTrpXtC.zip |

### 醫學 (`medicine`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。彙整自「醫學名詞」「藥學」「人體解剖學」「醫學名詞-醫事檢驗名詞」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 醫學名詞壓縮檔_GdCMZyw.zip | `3385875eca7ee90698f788dc4e996df8bf4cc31a6781e24ec8129fe5a2b5fe80` | 4 | 30797 | https://terms.naer.edu.tw/media/terms_data/1/醫學名詞壓縮檔_GdCMZyw.zip |
| 藥學壓縮檔_KaFonff.zip | `4e21ceb9ed8ea87c4c6e69dd4adc570e1f6f843c7be374c89306a433d12fb6be` | 1 | 5450 | https://terms.naer.edu.tw/media/terms_data/1/藥學壓縮檔_KaFonff.zip |
| 人體解剖學壓縮檔.zip | `c977adedc579dba73b02c0c14baac7f3852e6bb0d57c1d1134dcf321dce747d8` | 1 | 6431 | https://terms.naer.edu.tw/media/terms_data/1/人體解剖學壓縮檔.zip |
| 醫學名詞-醫事檢驗名詞壓縮檔.zip | `ce93d1c6cd1be35e1984e4666c1b9c697618f53ae7b02390d30678ef3c36e51e` | 1 | 3298 | https://terms.naer.edu.tw/media/terms_data/1/醫學名詞-醫事檢驗名詞壓縮檔.zip |

### 財經 (`finance`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。彙整自「經濟學」「會計學」「法律學名詞-財經法」三個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 經濟學壓縮檔.zip | `824d0d77815e6fc3de9c2d390e6fcf84737d923074c877d9d8973f7a947bec42` | 1 | 7357 | https://terms.naer.edu.tw/media/terms_data/1/經濟學壓縮檔.zip |
| 會計學壓縮檔.zip | `d359570562b63ce275a5989c84faff6bf28845f2675226ac63039569de3c478b` | 1 | 4878 | https://terms.naer.edu.tw/media/terms_data/1/會計學壓縮檔.zip |
| 法律學名詞-財經法壓縮檔.zip | `2a7ba472f4d2408c70f2a5d835b5e37778f456f47520416917b87238e0a60fa2` | 1 | 1375 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-財經法壓縮檔.zip |

### 法律 (`law`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。彙整自「法律學名詞-民法」「刑法」「公法」「國際法」「社會法」「性別與家事法」六個子集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 法律學名詞-民法壓縮檔_D9FrAig.zip | `1597c76d12989bd4897c78bd7a8d7db9b0538273548881959890dcb726aab9d3` | 1 | 443 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-民法壓縮檔_D9FrAig.zip |
| 法律學名詞-刑法壓縮檔.zip | `f240175ed77b92a9d60bc401b2dbcb00a3db673134cc538e28dc1a74fadeca3b` | 1 | 560 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-刑法壓縮檔.zip |
| 法律學名詞-公法壓縮檔.zip | `5b74b2b13149de0ed840809181d1030a92982ad4520fb9569e7621b267acd0ea` | 1 | 444 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-公法壓縮檔.zip |
| 法律學名詞-國際法壓縮檔.zip | `86e5d6a5bb24138b45460ab8d43de7ebf4530a5e22405b6f89b0e04a80c7c292` | 1 | 1340 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-國際法壓縮檔.zip |
| 法律學名詞-社會法壓縮檔.zip | `242b4dfcd84fa510d66a8702dbde47d5d2a008371b5aec1735f1fd4981ab6d3f` | 1 | 266 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-社會法壓縮檔.zip |
| 法律學名詞-性別與家事法壓縮檔.zip | `581602c9da02f45e2abbaa4a956e8edecf9890e706bbcf50186cca95f71ade22` | 1 | 574 | https://terms.naer.edu.tw/media/terms_data/1/法律學名詞-性別與家事法壓縮檔.zip |

### 工程 (`engineering`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。彙整自「電機工程名詞」「土木工程名詞」「土木工程名詞-結構及材料」「土木工程名詞-交通運輸」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 電機工程名詞壓縮檔_yZhCtnH.zip | `db2ae183f382fd8272fcf2b01fc30bcfbe42592f473e655a442fd3c316a265d3` | 19 | 184407 | https://terms.naer.edu.tw/media/terms_data/1/電機工程名詞壓縮檔_yZhCtnH.zip |
| 土木工程名詞壓縮檔.zip | `e66a0bd004d05f28d8e3b1180fab819fc10ff7f0a5641be1aaca9c5c35ce9e5d` | 3 | 28896 | https://terms.naer.edu.tw/media/terms_data/1/土木工程名詞壓縮檔.zip |
| 土木工程名詞-結構及材料壓縮檔.zip | `2a3a4d34bac931d221b308678fcf6f74b9b57aabd3c3b48068317770f68a01e8` | 1 | 4107 | https://terms.naer.edu.tw/media/terms_data/1/土木工程名詞-結構及材料壓縮檔.zip |
| 土木工程名詞-交通運輸壓縮檔.zip | `69f5eb5fcd8cff03fafad274b43c92235ae80b8397adc684a94d8af5223b8ae4` | 1 | 1731 | https://terms.naer.edu.tw/media/terms_data/1/土木工程名詞-交通運輸壓縮檔.zip |

### 音樂與音響 (`music`)

- 來源名稱：國家教育研究院 樂詞網（學術名詞下載）
- 來源網址：https://terms.naer.edu.tw/download/1/
- 授權名稱：國家教育研究院 樂詞網 — 政府網站資料開放宣告
- 授權網址：https://terms.naer.edu.tw/mysite/about/2/
- 顯名：原資料提供者：國家教育研究院。彙整自「音樂名詞」「音樂名詞-樂器名」「音樂名詞-音樂家」「音樂名詞-流行音樂專有名詞音響類」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。

Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：

| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |
|---|---|---|---|---|
| 音樂名詞壓縮檔_x2PEsPe.zip | `b3b4758e90e1e56a947ff136394b393bfda2aff67fddc9437db4f503b0635cd9` | 2 | 10425 | https://terms.naer.edu.tw/media/terms_data/1/音樂名詞壓縮檔_x2PEsPe.zip |
| 音樂名詞-樂器名壓縮檔.zip | `de489813b0b597104a95348f74b0de99ce36da431bc53e2f18e7c2c53daa08a3` | 1 | 714 | https://terms.naer.edu.tw/media/terms_data/1/音樂名詞-樂器名壓縮檔.zip |
| 音樂名詞-音樂家壓縮檔.zip | `814aff9afed2ad190d9723bf30d96264e46ad5670163aeecb5d728b7adf87198` | 1 | 6028 | https://terms.naer.edu.tw/media/terms_data/1/音樂名詞-音樂家壓縮檔.zip |
| 音樂名詞-流行音樂專有名詞音響類壓縮檔.zip | `2d19279d184bcfb0c754447ccc04216a540f69953c43e28ba6278a1eb18a4312` | 1 | 577 | https://terms.naer.edu.tw/media/terms_data/1/音樂名詞-流行音樂專有名詞音響類壓縮檔.zip |

## 跨來源補充

工單禁止來源（已排除，catalog 不引用）：

- **搜狗官方** `https://pinyin.sogou.com/help.php?list=9&q=1`：權利未開放
- **教育部國語辭典 CC BY-ND**：與學術名詞不同源，不混稱

授權與授權點解證據：見 `data-evidence/licenses/LICENSE-EVIDENCE.md` 與原始開放宣告 HTML（`naer-statement.html`）。

## Provenance（重建入口）

本目錄可用 `scripts/build-vocabulary-catalog.py` 從 raw cache 重建 catalog/termsFile/NOTICE。
raw cache 的 SHA256 與上游 URL 由 `data/vocabulary/sources.json`（repo 正本）固定：

```bash
# 用 sources.json 驗 hash + 重讀（推薦；預設）
python3 scripts/build-vocabulary-catalog.py \
    --raw-dir <raw cache> --out-dir data/vocabulary

# 用 sources.json 重新下載（會核 hash，fail-closed）
python3 scripts/build-vocabulary-catalog.py \
    --raw-dir <raw cache> --out-dir data/vocabulary --download
```

上表已列出每個 zip 的完整 URL 與完整 sha256，可獨立查驗。
授權文字與證據頁面：https://terms.naer.edu.tw/mysite/about/2/
