#!/usr/bin/env python3
"""build_vocabulary_catalog — UTUVO Type 詞庫 catalog 重建腳本

從 raw cache（`--raw-dir`）讀取六類 NAER 樂詞網 ODS 壓縮檔，產出
`catalog.json` + `NOTICE.md`，全部走 stdlib（zipfile + xml + csv）。

--download 不在這裡執行；網路下載屬上游 raw download 腳本。
這支腳本**只讀** raw dir 並**只寫**指定輸出檔，不變更工作樹其他部分。

用法：
    python3 build-vocabulary-catalog.py \\
        --raw-dir ../data-evidence/raw \\
        --out-dir ../data/vocabulary \\
        --manifest ../data-evidence/manifest.json

所有檔案路徑都必須存在；缺檔會 fail-closed（exit 1）。
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from typing import Iterable

NS = {
    "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
}
NS_TABLE = "{%s}" % NS["table"]
NS_TEXT = "{%s}" % NS["text"]

# 中文標點與 ASCII 控制字元：清洗時移除
_CTRL = re.compile(r"[\x00-\x08\x0b\x0e-\x1f\x7f]")
_HTML = re.compile(r"<[^>]+>")
_TAG_BR = re.compile(r"<br\s*/?>", re.IGNORECASE)
_HTML_ENTITY = re.compile(r"&(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);")
_FORMULA = re.compile(r"[\{\[].*?[\}\]]")  # 公式常見括號式

# 詞目長度邊界（工單：2–40 字元）
MIN_LEN = 2
MAX_LEN = 40

# catalog 契約
SCHEMA_VERSION = 2

# 授權（CONTRACT-V2 要求：不可冒稱 OGDL；六包唯一適用樂詞網自身的開放宣告）
LICENSE_NAME = "國家教育研究院 樂詞網 — 政府網站資料開放宣告"
LICENSE_URL = "https://terms.naer.edu.tw/mysite/about/2/"
SOURCE_NAME = "國家教育研究院 樂詞網（學術名詞下載）"
SOURCE_URL = "https://terms.naer.edu.tw/download/1/"

# 套件定義：每包收錄哪些 zip、來源/授權、summary、顯名、seed 候選（依本包常用專業術語）
# name/summary 繁中；runtime 另翻簡中
# seedCandidates 依 CONTRACT-V2：「從本包確實存在的詞選 20–40 個有代表性的日常專業術語」
PACKS = [
    {
        "id": "computing",
        "name": "資訊與電腦",
        "summary": "電子計算機學術名詞：程式語言、演算法、資料結構、系統軟硬體等核心詞彙。",
        "attribution": "原資料提供者：國家教育研究院。詞目取自「電子計算機名詞」資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "人工智慧", "機器學習", "資料庫", "作業系統", "演算法", "程式語言",
            "編譯器", "電腦", "網路", "物聯網", "大數據", "雲端", "雲端運算",
            "深度學習", "神經網路", "作業系統", "區塊鏈", "資訊安全", "密碼學",
            "資料結構", "物件導向", "開放原始碼", "虛擬實境", "擴增實境",
            "邊緣運算", "分散式", "平行運算", "即時系統", "嵌入式系統",
            "作業系統核心", "即時作業系統", "分散式運算", "影像處理",
            "圖形識別", "語音識別", "自然語言", "搜尋引擎", "資料探勘",
        ],
        "zips": [
            "電子計算機名詞壓縮檔_cTrpXtC.zip",
        ],
    },
    {
        "id": "medicine",
        "name": "醫學",
        "summary": "醫學、藥學、人體解剖、醫事檢驗等學術名詞：常用疾病、藥物、解剖構造、檢驗項目。",
        "attribution": "原資料提供者：國家教育研究院。彙整自「醫學名詞」「藥學」「人體解剖學」「醫學名詞-醫事檢驗名詞」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "心肌梗塞", "高血壓", "糖尿病", "肺炎", "抗生素", "疫苗",
            "動脈", "靜脈", "心臟", "肝臟", "腎臟", "腫瘤", "臨床試驗",
            "支氣管炎", "胃炎", "肝炎", "肝硬化", "腎衰竭", "透析",
            "心律不整", "心房顫動", "腦中風", "癲癇", "貧血", "骨折",
            "關節炎", "過敏", "發燒", "頭痛", "腹痛", "腹瀉", "便秘",
            "氣喘", "腦血管", "心包膜", "心肌", "冠狀動脈", "免疫",
            "抗體", "抗原", "紅血球", "白血球", "血小板", "血壓",
        ],
        "zips": [
            "醫學名詞壓縮檔_GdCMZyw.zip",
            "藥學壓縮檔_KaFonff.zip",
            "人體解剖學壓縮檔.zip",
            "醫學名詞-醫事檢驗名詞壓縮檔.zip",
        ],
    },
    {
        "id": "finance",
        "name": "財經",
        "summary": "經濟、會計、財經法相關學術名詞：總體經濟、財務會計、保險金融、稅務等。",
        "attribution": "原資料提供者：國家教育研究院。彙整自「經濟學」「會計學」「法律學名詞-財經法」三個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "資產負債表", "現金流量", "資本市場", "股票", "債券", "基金",
            "利率", "匯率", "通貨膨脹", "投資", "風險", "資產", "負債",
            "保險", "期貨", "選擇權", "外匯", "央行", "存款準備金",
            "公開市場操作", "國民所得", "經濟成長", "失業率", "消費者物價指數",
            "國內生產毛額", "金融海嘯", "金融危機", "衍生性金融商品", "主權債信",
            "信用評等", "信用風險", "市場風險", "流動性風險", "作業風險",
            "資產配置", "投資組合", "避險", "套利", "私募基金", "創投",
            "首次公開發行", "可轉換公司債", "股東會", "董事會", "審計委員會",
        ],
        "zips": [
            "經濟學壓縮檔.zip",
            "會計學壓縮檔.zip",
            "法律學名詞-財經法壓縮檔.zip",
        ],
    },
    {
        "id": "law",
        "name": "法律",
        "summary": "法律學術名詞：憲法（公法）、刑法、民法、國際法、社會法、家事法等核心法領域詞彙。",
        "attribution": "原資料提供者：國家教育研究院。彙整自「法律學名詞-民法」「刑法」「公法」「國際法」「社會法」「性別與家事法」六個子集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "損害賠償", "憲法", "民法", "刑法", "訴訟", "判決", "契約",
            "物權", "債權", "抵押權", "保證", "時效", "正當防衛",
            "被告", "原告", "當事人", "代理人", "期間", "期日", "裁定",
            "沒收", "追徵", "民事", "繼承人", "債權人", "債務人", "調解",
            "和解", "仲裁", "公證", "舉證", "證據", "管轄", "迴避",
            "上訴", "再審", "非常上訴", "緩刑", "假釋", "保安處分",
            "有期徒刑", "無期徒刑", "拘役", "罰金", "拘提", "羈押",
            "搜索", "扣押", "侵占", "詐欺", "重利", "誹謗", "公然",
            "妨害秘密", "強制性交", "公訴", "自訴", "辯護人", "告訴人",
        ],
        "zips": [
            "法律學名詞-民法壓縮檔_D9FrAig.zip",
            "法律學名詞-刑法壓縮檔.zip",
            "法律學名詞-公法壓縮檔.zip",
            "法律學名詞-國際法壓縮檔.zip",
            "法律學名詞-社會法壓縮檔.zip",
            "法律學名詞-性別與家事法壓縮檔.zip",
        ],
    },
    {
        "id": "engineering",
        "name": "工程",
        "summary": "電機與土木工程學術名詞：電路、訊號、控制、材料、結構、交通運輸、大地工程等。",
        "attribution": "原資料提供者：國家教育研究院。彙整自「電機工程名詞」「土木工程名詞」「土木工程名詞-結構及材料」「土木工程名詞-交通運輸」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "鋼筋混凝土", "半導體", "電路", "變壓器", "發電機", "電動機",
            "電晶體", "光纖", "無線電", "天線", "隧道", "鋼構", "混凝土",
            "結構", "電機", "電壓", "電流", "電阻", "電容", "電感",
            "訊號", "控制", "感測", "量測", "振動", "應力", "應變",
            "材料", "鋼筋", "桁架", "基礎", "開挖", "連續壁", "基樁",
            "電力", "通訊", "積體電路", "二極體", "電阻器", "電容器",
            "繼電器", "斷路器", "焊接", "金屬", "合金", "不鏽鋼",
        ],
        "zips": [
            "電機工程名詞壓縮檔_yZhCtnH.zip",
            "土木工程名詞壓縮檔.zip",
            "土木工程名詞-結構及材料壓縮檔.zip",
            "土木工程名詞-交通運輸壓縮檔.zip",
        ],
    },
    {
        "id": "music",
        "name": "音樂與音響",
        "summary": "音樂學術名詞：樂理、樂器、音樂家、流行音樂專有名詞（含音響類）等。",
        "attribution": "原資料提供者：國家教育研究院。彙整自「音樂名詞」「音樂名詞-樂器名」「音樂名詞-音樂家」「音樂名詞-流行音樂專有名詞音響類」四個資料集。本詞表經格式清理、註解移除、同義詞拆分及去重。",
        "seedCandidates": [
            "麥克風", "混音", "頻率", "音場", "和聲", "旋律", "節奏",
            "調性", "音程", "音色", "音量", "音階", "拍子", "鋼琴",
            "小提琴", "吉他", "低音", "高音", "頌歌", "室內樂", "交響曲",
            "奏鳴曲", "協奏曲", "獨奏曲", "對位", "卡農", "賦格", "詠嘆調",
            "重唱", "合唱", "變奏曲", "圓舞曲", "波蘭舞曲", "進行曲", "夜曲",
            "前奏曲", "間奏曲", "幻想曲", "隨想曲", "練習曲", "即興曲",
            "搖籃曲", "安魂曲", "彌撒曲", "聖詠", "清唱劇", "歌劇",
        ],
        "zips": [
            "音樂名詞壓縮檔_x2PEsPe.zip",
            "音樂名詞-樂器名壓縮檔.zip",
            "音樂名詞-音樂家壓縮檔.zip",
            "音樂名詞-流行音樂專有名詞音響類壓縮檔.zip",
        ],
    },
]

VERSION = "2026-09-20"
SEED_PER_PACK_MIN = 20
SEED_PER_PACK_MAX = 40


# ---------- 解析 ----------

def _strip_text(s: str) -> str:
    """去 HTML / 公式 / 連續空白；保留必要 ASCII/標點。"""
    if not s:
        return ""
    s = html.unescape(s)
    s = _HTML.sub(" ", s)            # 任何 <tag> → 空白
    s = _TAG_BR.sub(" ", s)          # <br>
    s = _HTML_ENTITY.sub(" ", s)     # 殘餘 entity
    s = _CTRL.sub("", s)
    s = s.replace("　", " ")     # 全形空白
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _has_cjk(s: str) -> bool:
    return any("一" <= ch <= "鿿" for ch in s)


def _walk_ods_text(node: ET.Element) -> str:
    """Walk an ODS text subtree and yield visible characters.

    Handles:
    - 元素自己的 text
    - 每個 child 的 tail（ODS 重要：span 的 tail 是該 span 之後的『接續』字元）
    - `<text:s text:c="N">` 或 `<text:s>N</text:s>` → N 個半形空白
    - `<text:tab/>` → \\t

    同一段字不會重複：手動管理序列、不再疊 itertext 與子節點 itertext。
    """
    out: list[str] = []
    # Node's own text (children of text:p/text:span typically empty here)
    if node.text:
        out.append(node.text)
    for child in node:
        tag = child.tag
        if tag == NS_TEXT + "s":
            # ODS space: text:s with text:c (count) or text content
            cnt = child.get(NS_TEXT + "c") or (child.text or "1").strip() or "1"
            try:
                n = max(1, int(cnt))
            except ValueError:
                n = 1
            out.append(" " * n)
            if child.tail:
                out.append(child.tail)
            continue
        if tag == NS_TEXT + "tab":
            out.append("\t")
            if child.tail:
                out.append(child.tail)
            continue
        # Generic: recurse into child
        out.append(_walk_ods_text(child))
        if child.tail:
            out.append(child.tail)
    return "".join(out)


def _cell_text(cell: ET.Element) -> str:
    """Extract visible text from an ODS table:table-cell.

    使用 _walk_ods_text 走訪整個 cell（包含 <text:p> 內所有 span/space/tab），
    不再疊加 itertext 與 span 子節點（避免 nested span 重複追加）。
    """
    parts: list[str] = []
    for p in cell.findall("text:p", NS):
        text = _walk_ods_text(p).strip()
        if text:
            parts.append(text)
    return _strip_text(" ".join(parts))


def _expand_repeat(cell: ET.Element, header_cols: int) -> Iterable[str]:
    """Yield cell text once, or N times if number-columns-repeated."""
    repeat = cell.get(f"{NS_TABLE}number-columns-repeated")
    text = _cell_text(cell)
    if repeat is None:
        yield text
        return
    try:
        n = int(repeat)
    except ValueError:
        n = 1
    n = max(1, n)
    # Avoid pathological: cap at header width (defensive)
    n = min(n, max(header_cols, 1))
    for _ in range(n):
        yield text


def _row_cells(row: ET.Element, header_cols: int) -> list[str]:
    out: list[str] = []
    for tc in row.findall("table:table-cell", NS):
        out.extend(_expand_repeat(tc, header_cols))
    return out


def parse_ods(path: str) -> tuple[list[str], list[list[str]]]:
    """Return (header, rows). Header is the first row."""
    with zipfile.ZipFile(path) as z:
        with z.open("content.xml") as f:
            tree = ET.parse(f)
    tables = list(tree.getroot().iter(f"{NS_TABLE}table"))
    if not tables:
        return [], []
    tbl = tables[0]
    raw_rows = tbl.findall("table:table-row", NS)
    if not raw_rows:
        return [], []
    # Use first row to learn header column count
    header_cells = _row_cells(raw_rows[0], header_cols=20)
    header_cols = max(len(header_cells), 1)
    header = header_cells
    rows = [_row_cells(r, header_cols) for r in raw_rows[1:]]
    # Trim trailing empty cells
    rows = [r[: len(header)] + [""] * max(0, len(header) - len(r)) for r in rows]
    return header, rows


# ---------- 清洗與篩選 ----------

SEMI = "；"  # 中文分號用來拆同義詞
# 各種括號（左／右集合分清楚）
_LEFT_BRACKETS = r"\(\[\{（［【﹝﹙｛"
_RIGHT_BRACKETS = r"\)\]\}）］】﹞﹚｝"
# 〈〉《》夾註
ANGLE_BRACKET_TAIL = re.compile(r"[〈《].*?[〉》]")
# 詞首非 CJK 非 word 字元
LEADING_PUNCT = re.compile(r"^[^\w一-鿿]+")
# CONTRACT-V2：拒絕數字編號片段（"7) 碼"、"b) 樹" 這類被破壞的標籤）
CODE_FRAGMENT_LEAD = re.compile(r"^[A-Za-z0-9]+\)")
# 檔案副檔名／版本字首（".AFM 格式檔案"）— 大多為格式標籤，非真實詞目；仍保留，但略可接受
DOT_PREFIX = re.compile(r"^\.[A-Za-z]+")
# 公式常見開頭：希臘字母／數學符號帶運算子
FORMULA_FRAGMENT = re.compile(r"[=<>±∑∏∫√∞∂∇∝≡≅≤≥≠→←↔⇒⇐]")
# 內部空白（半形或全形空格）— 詞目必須連續，不允許中段空白
INNER_WS = re.compile(r"[ 　\t]")


def _has_unbalanced_brackets(s: str) -> bool:
    """回傳是否含不平衡的半形或全形括號/方括號/大括號（計數左右）。"""
    pairs = [
        ("(", ")"), ("[", "]"), ("{", "}"),
        ("（", "）"), ("［", "］"), ("｛", "｝"),
        ("【", "】"), ("﹝", "﹞"),
    ]
    for lo, rc in pairs:
        if s.count(lo) != s.count(rc):
            return True
    return False


def _split_top_level(s: str, seps: str) -> list[str]:
    """以 seps 中任一字元切 s，但跳過所有括號內部（depth-aware）。

    回傳的片段已去除外部前導／尾端空白；空片段不保留。
    """
    parts: list[str] = []
    buf: list[str] = []
    depth = 0
    for ch in s:
        if ch in _LEFT_BRACKETS or ch in _RIGHT_BRACKETS:
            # depth tracking：左右集合各自獨立計數，但概念上左右都進入／離開 depth
            if ch in _LEFT_BRACKETS:
                depth += 1
                buf.append(ch)
            else:
                depth = max(0, depth - 1)
                buf.append(ch)
            continue
        if ch in seps and depth == 0:
            parts.append("".join(buf).strip())
            buf = []
            continue
        buf.append(ch)
    rest = "".join(buf).strip()
    if rest:
        parts.append(rest)
    return [p for p in parts if p]


def _strip_brackets(s: str) -> str:
    """剝掉 s 內所有完整配對的括號內容（含其餘內容）。不平衡就直接原樣回傳。"""
    # 反覆掃描直到不再有完整 pair
    while True:
        # 找最早的左括號位置
        idx = None
        for ch in _LEFT_BRACKETS:
            i = s.find(ch)
            if i >= 0 and (idx is None or i < idx):
                idx = i
        if idx is None:
            return s
        # 從 idx 起做括號配對，找到對應右括號
        stack = [s[idx]]
        j = idx + 1
        depth = 1
        while j < len(s) and depth > 0:
            c = s[j]
            if c in _LEFT_BRACKETS:
                depth += 1
                stack.append(c)
            elif c in _RIGHT_BRACKETS:
                depth -= 1
                stack.append(c)
            j += 1
        if depth != 0:
            return s  # 不平衡，留原樣給上層拒絕
        end = idx + (j - idx)  # 切到右括號之後
        s = s[:idx] + s[end:]
    # 不可達，但 lint 友善


def clean_terms(cell_text: str) -> list[str]:
    """從單一 cell 抽出多個候選詞。

    CONTRACT-V2 / FINDING-2 規則：
    - 真正不平衡括號的輸入 → 直接拒絕（回傳 []）
    - depth-aware 拆分：';' / ',' 只在 depth==0 才切；避免拆掉括號內註解
    - 拆完再剝每段的括號註解（_strip_brackets）；若剝後仍不平衡 → 整段拒絕
    - 詞首 / 詞尾若仍剩孤立右括號 → 整段拒絕（不能當詞）
    - 其他既有拒絕規則（編號片段、短副檔名、公式、內部空白等）保留
    """
    if not cell_text:
        return []
    s = cell_text.strip()
    # 〈〉夾註移除
    s = ANGLE_BRACKET_TAIL.sub("", s)
    # 1) 整體不平衡 → 拒絕整個 cell
    if _has_unbalanced_brackets(s):
        return []
    # 2) depth-aware 拆分（只在括號外才切）
    parts = _split_top_level(s, ";,；，")
    out: list[str] = []
    for p in parts:
        t = p.strip()
        if not t:
            continue
        # 3) 剝括號註解（已配對的內容）
        t = _strip_brackets(t)
        t = t.strip()
        if not t:
            continue
        # 4) 拒絕條目：剝完仍不平衡（含 _RIGHT_BRACKETS 多餘）
        if any(ch in _RIGHT_BRACKETS for ch in t):
            continue
        if any(ch in _LEFT_BRACKETS for ch in t):
            continue
        # 5) 詞首是單一數字/英文字母後接 ) 的編號彙片
        if CODE_FRAGMENT_LEAD.match(t):
            continue
        # 6) 短副檔名前綴
        if DOT_PREFIX.match(t) and len(t) < 15:
            continue
        # 7) 公式運算子
        if FORMULA_FRAGMENT.search(t):
            continue
        # 8) 內部空白（詞中段應連續）
        if INNER_WS.search(t):
            continue
        # 9) 去除尾端點號與頓號
        t = t.rstrip("。.．、,，;； ")
        if not t:
            continue
        # CONTRACT-V2 拒絕規則
        if CODE_FRAGMENT_LEAD.match(t):
            continue
        if DOT_PREFIX.match(t) and len(t) < 15:
            # 短副檔名前綴（".AFM"）視為格式標籤，不列入詞庫
            continue
        if FORMULA_FRAGMENT.search(t):
            continue
        if _has_unbalanced_brackets(t):
            continue
        # 拒絕內部含空白的詞（如「嬰兒 ｛定義｝」、「1/v 吸收體」）
        if INNER_WS.search(t):
            continue
        if len(t) < MIN_LEN or len(t) > MAX_LEN:
            continue
        if not _has_cjk(t):
            continue
        # 跳過詞首只剩標點的詞
        if LEADING_PUNCT.match(t):
            continue
        # 跳過詞尾只剩標點的詞
        if not any(ch.isalnum() or "一" <= ch <= "鿿" for ch in t):
            continue
        out.append(t)
    return out


def extract_terms_from_zip(raw_dir: str, zip_filename: str) -> tuple[list[str], dict]:
    """從 zip → 所有 ODS → 抽出『中文名稱』欄位的所有詞目。回傳 (terms_raw, info)。"""
    zip_path = os.path.join(raw_dir, zip_filename)
    info = {"filename": zip_filename, "ods_files": [], "rows_total": 0}
    all_terms: list[str] = []
    with zipfile.ZipFile(zip_path) as z:
        ods_names = sorted(n for n in z.namelist() if n.endswith(".ods"))
        info["ods_files"] = ods_names
        for ods in ods_names:
            # ODS is itself a zip; open it as zipfile and parse inner content.xml
            with z.open(ods) as ods_stream:
                with zipfile.ZipFile(ods_stream) as ods_zip:
                    inner = [n for n in ods_zip.namelist() if n.endswith("content.xml")]
                    if not inner:
                        continue
                    with ods_zip.open(inner[0]) as cx:
                        tree = ET.parse(cx)
            tables = list(tree.getroot().iter(f"{NS_TABLE}table"))
            if not tables:
                continue
            tbl = tables[0]
            raw_rows = tbl.findall("table:table-row", NS)
            if len(raw_rows) < 2:
                continue
            header_cells = _row_cells(raw_rows[0], header_cols=20)
            # Find 中文名稱 column
            cn_idx = -1
            for i, h in enumerate(header_cells):
                if h in ("中文名稱", "中文名詞"):
                    cn_idx = i
                    break
            if cn_idx < 0:
                # skip if no Chinese column found
                continue
            info["rows_total"] += max(0, len(raw_rows) - 1)
            for row in raw_rows[1:]:
                cells = _row_cells(row, header_cols=len(header_cells))
                if cn_idx >= len(cells):
                    continue
                all_terms.extend(clean_terms(cells[cn_idx]))
    return all_terms, info


def dedup_keep_order(items: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for it in items:
        if it in seen:
            continue
        seen.add(it)
        out.append(it)
    return out


def select_seeds(term_set: set[str], candidates: list[str]) -> list[str]:
    """CONTRACT-V2：從 curated 候選清單中，挑實際存在於本包的詞，依原順序保留前 N 個。

    不再做等距抽樣。候選清單已是「日常專業術語」的優先序；若不足 20 個再由管理員補。
    """
    out: list[str] = []
    seen: set[str] = set()
    for c in candidates:
        if c in term_set and c not in seen:
            out.append(c)
            seen.add(c)
    return out[:SEED_PER_PACK_MAX]


# ---------- 主流程 ----------

def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def load_sources(path: str) -> dict[str, dict]:
    """讀 sources.json；key by filename，回傳 dict。

    DELTA-FIX #1：JSON 不是 list、任一元素缺 filename，皆 fail-closed（raise）。
    """
    with open(path, encoding="utf-8") as f:
        rows = json.load(f)
    if not isinstance(rows, list):
        raise SystemExit(f"sources.json 必須是 list，實為 {type(rows).__name__}")
    out: dict[str, dict] = {}
    for i, row in enumerate(rows):
        if not isinstance(row, dict) or "filename" not in row:
            raise SystemExit(f"sources.json[{i}] 缺 filename 或不是 dict")
        out[row["filename"]] = row
    return out


def download_from_sources(sources: dict[str, dict], raw_dir: str) -> None:
    """用 curl 下載所有 sources.json 列出的 zip 到 raw_dir；下載完立即核 sha256。

    任何 hash 不符 → 整批 abort（Failing closed）。
    """
    os.makedirs(raw_dir, exist_ok=True)
    failures: list[tuple[str, str, str]] = []  # (filename, expected, actual)
    for fn, info in sources.items():
        url = info["url"]
        out_path = os.path.join(raw_dir, fn)
        if os.path.exists(out_path):
            cur = sha256_of(out_path)
            if cur == info["sha256"]:
                print(f"[skip cached] {fn}")
                continue
            print(f"[hash mismatch; re-fetch] {fn}")
        # URL 含中文檔名；curl 會自動處理
        rc = subprocess.run(
            ["curl", "-sS", "-L", "-o", out_path, url],
            check=False,
        ).returncode
        if rc != 0:
            failures.append((fn, info["sha256"], f"curl rc={rc}"))
            continue
        actual = sha256_of(out_path)
        if actual != info["sha256"]:
            failures.append((fn, info["sha256"], actual))
            os.remove(out_path)
    if failures:
        for fn, exp, act in failures:
            print(f"FAIL {fn}: expected={exp[:16]}… actual={act}", file=sys.stderr)
        raise SystemExit(2)


def write_terms_txt(path: str, terms: list[str]) -> str:
    """CONTRACT-V2：UTF-8、LF、一行一詞、尾 LF。回傳 sha256。"""
    # 為了保證穩定順序、測試可重現，這裡再排一次（已 dedup_keep_order）
    payload = "\n".join(terms) + "\n"
    raw = payload.encode("utf-8")
    # 強制 LF：若有 CRLF，轉 LF
    raw = raw.replace(b"\r\n", b"\n")
    with open(path, "wb") as f:
        f.write(raw)
    return hashlib.sha256(raw).hexdigest()


def build_catalog(raw_dir: str, out_dir: str, manifest_path: str | None,
                  sources: dict[str, dict] | None = None) -> dict:
    # DELTA-FIX #2：NOTICE 與 metadata 用固定 VERSION 日期（非 date.today），
    # 同 raw cache + 同 VERSION 下跨日重建也應得到完全相同的 bytes。
    today = VERSION
    manifest = {}
    if manifest_path and os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            for row in json.load(f):
                manifest[row["filename"]] = row
    os.makedirs(out_dir, exist_ok=True)
    packs_out = []
    raw_inventory = []
    for pack in PACKS:
        all_terms: list[str] = []
        per_zip_info = []
        for zfn in pack["zips"]:
            zpath = os.path.join(raw_dir, zfn)
            if not os.path.exists(zpath):
                raise SystemExit(f"raw cache 缺檔：{zpath}")
            # DELTA-FIX #1：sources 必為必填，每一個 PACKS 引用的 zip 都必須
            # 在 sources.json 內（無『只讀檔不驗證』的後門）。
            if zfn not in sources:
                raise SystemExit(
                    f"{zfn} 不在 sources.json 內；PACKS 與 sources.json 必須一致"
                )
            expected = sources[zfn]["sha256"]
            actual = sha256_of(zpath)
            if actual != expected:
                raise SystemExit(
                        f"{zfn} raw hash 不符 sources.json！expected={expected[:16]}… actual={actual[:16]}…；可能來源被竄改或下載損壞"
                    )
            terms, info = extract_terms_from_zip(raw_dir, zfn)
            info["sha256"] = sha256_of(zpath)
            # URL/sha 來源：優先用 sources.json（repo 正本）；fallback 至私有 manifest
            if sources and zfn in sources:
                info["source_url"] = sources[zfn]["url"]
                info["source_sha256"] = sources[zfn]["sha256"]
                info["source_bytes"] = sources[zfn].get("bytes")
                info["source_fetched_at"] = sources[zfn].get("fetchedAt", "")
            else:
                info["source_url"] = manifest.get(zfn, {}).get("url", "")
            all_terms.extend(terms)
            per_zip_info.append(info)
            raw_inventory.append(info)
        # 去重保序
        terms_clean = dedup_keep_order(all_terms)
        # 確保 ≥300（工單要求每包至少 300 個乾淨實際詞）
        if len(terms_clean) < 300:
            raise SystemExit(
                f"{pack['id']}: 清洗後 {len(terms_clean)} 筆，少於工單下限 300"
            )
        # CONTRACT-V2：seedTerms 從 curated 候選清單中選實際存在的代表詞（不再等距抽樣）
        term_set = set(terms_clean)
        seeds = select_seeds(term_set, pack["seedCandidates"])
        if len(seeds) < SEED_PER_PACK_MIN:
            raise SystemExit(
                f"{pack['id']}: 從 curated 候選只挑到 {len(seeds)} 個，少於工單下限 {SEED_PER_PACK_MIN}；需擴充候選清單"
            )
        # 寫 txt；記錄 sha256
        terms_file = f"{pack['id']}.txt"
        terms_path = os.path.join(out_dir, terms_file)
        terms_sha = write_terms_txt(terms_path, terms_clean)
        packs_out.append({
            "id": pack["id"],
            "name": pack["name"],
            "summary": pack["summary"],
            "sourceName": SOURCE_NAME,
            "sourceURL": SOURCE_URL,
            "licenseName": LICENSE_NAME,
            "licenseURL": LICENSE_URL,
            "attribution": pack["attribution"],
            "version": VERSION,
            "defaultOn": False,
            "seedTerms": seeds,
            "termsFile": terms_file,
            "termCount": len(terms_clean),
            "termsSHA256": terms_sha,
            "_meta": {  # 不寫進 catalog，僅用於 NOTICE
                "rawCount": sum(i["rows_total"] for i in per_zip_info),
                "files": per_zip_info,
            },
        })
    catalog = {
        "schemaVersion": SCHEMA_VERSION,
        "packs": [{k: v for k, v in p.items() if not k.startswith("_")} for p in packs_out],
    }
    return {
        "catalog": catalog,
        "packs_meta": [{k: v for k, v in p.items() if k.startswith("_") or k == "id"} for p in packs_out],
        "raw_inventory": raw_inventory,
        "date": today,
    }


def write_catalog(path: str, catalog: dict) -> None:
    # 工單：總 JSON 合理體積（目標 <8 MB）；採 minified 寫入
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, separators=(",", ":"), sort_keys=False)


def write_notice(path: str, packs_meta: list[dict], raw_inventory: list[dict], date: str) -> None:
    lines = []
    lines.append("# NOTICE — UTUVO Type 詞庫（type-vocabulary catalog）")
    lines.append("")
    lines.append(f"資料重建日期：{date}")
    lines.append(f"schemaVersion：{SCHEMA_VERSION}（catalog.json；metadata 與 terms 分檔）")
    lines.append("")
    lines.append("本目錄含六包：`computing`、`medicine`、`finance`、`law`、`engineering`、`music`。")
    lines.append("每包由兩個檔案組成：")
    lines.append("")
    lines.append("- `catalog.json` 中的 `<id>` 條目：metadata（指向 termsFile 與其 sha256）")
    lines.append("- `<id>.txt`：UTF-8、LF、一行一詞、尾 LF；該包的實際詞表")
    lines.append("")
    lines.append("## 授權（CONTRACT-V2：不可冒稱 OGDL）")
    lines.append("")
    lines.append("六包的資料源都是國家教育研究院 樂詞網（https://terms.naer.edu.tw/）下載專區的 zip 壓縮檔。")
    lines.append("這些資料集**沒有**出現在 data.gov.tw / data.nat.gov.tw / TAIC 等開放資料平台（已實證搜尋無命中），")
    lines.append("授權依據為樂詞網站自身的「政府網站資料開放宣告」：")
    lines.append("")
    lines.append(f"- 授權名稱：{LICENSE_NAME}")
    lines.append(f"- 授權網址：{LICENSE_URL}")
    lines.append("")
    lines.append("宣告重點（curl 取得後節錄）：")
    lines.append("> 為利各界廣為利用網站資料…以無償、非專屬、得再授權之方式提供公眾使用，使用者得不限時間及地域，")
    lines.append("> 重製、改作、編輯、公開傳輸或為其他方式之利用…使用時，應註明出處。")
    lines.append("")
    lines.append("並非 OGDL-Taiwan-1.0（雖然精神相近，但 OGDL 是另一份由國家發展委員會（NDC）維運的通用授權文件）。")
    lines.append("")
    lines.append("## 清洗規則（termsFile 產生流程）")
    lines.append("")
    lines.append("1. 從每個 zip 取所有內含的 ODS，解析 `<table:table-row>`。")
    lines.append("2. 以表頭識別『中文名稱』／『中文名詞』欄。")
    lines.append("3. 對每個 cell 文字：")
    lines.append("   - 先 unescape HTML entity；去 `<...>` 標籤；移除 ASCII 控制字元；合併連續空白")
    lines.append("   - 移除 `〈〉《》` 夾註")
    lines.append("4. 以 `;` ／ `,` ／ `；` ／ `，` 拆分同義詞並列（depth-aware：括號內不切）")
    lines.append("5. 詞首有 `﹝電磁﹞` 這類分類括號時剝掉該對，留下主詞")
    lines.append("6. 去除括號內解釋（如 `紅斑（紫外放射光）` → `紅斑`）")
    lines.append("7. 拒絕規則（CONTRACT-V2）：")
    lines.append("   - 半形括號 / 方括號 / 大括號左右不平衡的破壞片段")
    lines.append("   - 詞首數字或英文字母後接 `)` 的編號彙片（`7) 碼`、`b) 樹` 這類）")
    lines.append("   - 含 `=`, `∑`, `∫` 等數學運算子的公式片段")
    lines.append("   - 短副檔名前綴（`.AFM`、`.3GR`）視為格式標籤，不列入詞庫")
    lines.append("8. 跳過純英數、長度 <2 或 >40 的詞目")
    lines.append("9. 同包內全部 zip 合併後去重（保序）；輸出至 `<id>.txt`")
    lines.append("10. seedTerms 由 curated 清單中挑 20–40 個本包**確實存在**的日常專業術語（非等距抽樣）")
    lines.append("")
    lines.append("## 各包來源與顯名")
    lines.append("")
    for meta in packs_meta:
        pid = meta["id"]
        # Re-fetch pack def
        pack_def = next(p for p in PACKS if p["id"] == pid)
        # find corresponding catalog entry for termCount and termsSHA256
        lines.append(f"### {pack_def['name']} (`{pid}`)")
        lines.append("")
        lines.append(f"- 來源名稱：{SOURCE_NAME}")
        lines.append(f"- 來源網址：{SOURCE_URL}")
        lines.append(f"- 授權名稱：{LICENSE_NAME}")
        lines.append(f"- 授權網址：{LICENSE_URL}")
        lines.append(f"- 顯名：{pack_def['attribution']}")
        lines.append("")
        files = meta["_meta"]["files"]
        lines.append("Raw cache（檔名 → sha256 → ODS 數 → 原始筆數 → 來源網址）：")
        lines.append("")
        lines.append("| 檔名 | sha256 | ODS 數 | 原始筆數 | 來源網址 |")
        lines.append("|---|---|---|---|---|")
        for f in files:
            url = f["source_url"] or "(見 manifest.json)"
            lines.append(
                f"| {f['filename']} | `{f['sha256']}` | {len(f['ods_files'])} | {f['rows_total']} | {url} |"
            )
        lines.append("")
    lines.append("## 跨來源補充")
    lines.append("")
    lines.append("工單禁止來源（已排除，catalog 不引用）：")
    lines.append("")
    lines.append("- **搜狗官方** `https://pinyin.sogou.com/help.php?list=9&q=1`：權利未開放")
    lines.append("- **教育部國語辭典 CC BY-ND**：與學術名詞不同源，不混稱")
    lines.append("")
    lines.append("授權與授權點解證據：見 `data-evidence/licenses/LICENSE-EVIDENCE.md` 與原始開放宣告 HTML（`naer-statement.html`）。")
    lines.append("")
    lines.append("## Provenance（重建入口）")
    lines.append("")
    lines.append("本目錄可用 `scripts/build-vocabulary-catalog.py` 從 raw cache 重建 catalog/termsFile/NOTICE。")
    lines.append("raw cache 的 SHA256 與上游 URL 由 `data/vocabulary/sources.json`（repo 正本）固定：")
    lines.append("")
    lines.append("```bash")
    lines.append("# 用 sources.json 驗 hash + 重讀（推薦；預設）")
    lines.append("python3 scripts/build-vocabulary-catalog.py \\")
    lines.append("    --raw-dir <raw cache> --out-dir data/vocabulary")
    lines.append("")
    lines.append("# 用 sources.json 重新下載（會核 hash，fail-closed）")
    lines.append("python3 scripts/build-vocabulary-catalog.py \\")
    lines.append("    --raw-dir <raw cache> --out-dir data/vocabulary --download")
    lines.append("```")
    lines.append("")
    lines.append("上表已列出每個 zip 的完整 URL 與完整 sha256，可獨立查驗。")
    lines.append("授權文字與證據頁面：https://terms.naer.edu.tw/mysite/about/2/")
    lines.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--raw-dir", required=True, help="raw cache 目錄（含已下載 zip）")
    ap.add_argument("--out-dir", required=True, help="輸出 catalog.json/NOTICE.md 的目錄")
    ap.add_argument("--manifest", default=None,
                    help="私有 manifest.json（fallback，僅在無 sources.json 時使用）")
    ap.add_argument("--sources",
                    default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                         "data", "vocabulary", "sources.json"),
                    help="sources.json 路徑（預設讀 repo 正本；含完整 URL 與 sha256）；不存在或格式錯會 fail-closed（exit 2）")
    ap.add_argument("--download", action="store_true",
                    help="用 curl 從 sources.json URL 下載到 raw-dir（會驗 sha256）")
    args = ap.parse_args(argv)
    raw_dir = args.raw_dir
    out_dir = args.out_dir
    # DELTA-FIX #1：--sources 一旦被指定（含預設值），必須 fail-closed：
    # - 不存在 / 不是檔案 → SystemExit(2)
    # - JSON 解析失敗 / 不是 list → SystemExit(2)
    # - 任一元素缺 url/sha256，或 sha256 不是 64 字 hex → SystemExit(2)
    # 不再靜默放行 hash 驗證。預設 --sources 指向 repo 正本；若正本被誤刪則整個
    # build 必須立即失敗，而不是『讀不到就沒驗證』。
    if not args.sources:
        raise SystemExit("--sources 必須指定；不要走無驗證分支")
    if not os.path.isfile(args.sources):
        raise SystemExit(f"--sources 指向的路徑不存在或不是檔案：{args.sources}")
    sources = load_sources(args.sources)
    # schema/欄位完整性檢查：要求每一筆有 url（http(s)://）+ sha256（64 字 hex）
    bad: list[str] = []
    for fn, info in sources.items():
        url = info.get("url", "")
        sha = info.get("sha256", "")
        if not (isinstance(url, str) and url.startswith(("http://", "https://"))):
            bad.append(f"{fn}: url 缺失或不是 http(s)")
        if not (isinstance(sha, str) and len(sha) == 64 and all(c in "0123456789abcdef" for c in sha)):
            bad.append(f"{fn}: sha256 缺失或不是 64 字 hex")
    if bad:
        for b in bad:
            print(f"FAIL sources entry: {b}", file=sys.stderr)
        raise SystemExit(2)
    if args.download:
        print(f"Downloading {len(sources)} zips from sources.json …")
        download_from_sources(sources, raw_dir)
    if not os.path.isdir(raw_dir):
        print(f"raw-dir not a directory: {raw_dir}", file=sys.stderr)
        return 2
    result = build_catalog(raw_dir, out_dir, args.manifest, sources=sources)
    catalog_path = os.path.join(out_dir, "catalog.json")
    notice_path = os.path.join(out_dir, "NOTICE.md")
    write_catalog(catalog_path, result["catalog"])
    write_notice(notice_path, result["packs_meta"], result["raw_inventory"], result["date"])
    # 摘要印到 stdout
    for p in result["catalog"]["packs"]:
        print(
            f"[{p['id']:11}]  termCount={p['termCount']:6d}  seeds={len(p['seedTerms']):3d}  "
            f"termsFile={p['termsFile']:14s}  termsSHA={p['termsSHA256'][:12]}…"
        )
    print(f"\nWrote {catalog_path} and {notice_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())