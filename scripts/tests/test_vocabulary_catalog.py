#!/usr/bin/env python3
"""test_vocabulary_catalog — UTUVO Type 詞庫 catalog 隔離測試

純 stdlib（unittest）。只使用：
  - 已產出的 data/vocabulary/catalog.json 與 NOTICE.md（regression fixture）
  - scripts/build-vocabulary-catalog.py 的純函式（單元測試）
  - 自行建立的記憶體 fixture（不含真實 ODS 解析路徑）

不讀 prefs / keychain / 環境變數（除 PYTHONPATH）。
不執行網路下載。
"""
from __future__ import annotations

import json
import os
import re
import sys
import unittest
import zipfile
import xml.etree.ElementTree as ET
import tempfile
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
ROOT = os.path.dirname(SCRIPTS)
CATALOG = os.path.join(ROOT, "data", "vocabulary", "catalog.json")
NOTICE = os.path.join(ROOT, "data", "vocabulary", "NOTICE.md")

# 用 importlib 載入，避免依賴 sys.path 與 scripts/__init__.py
import importlib.util as _importlib_util
_SPEC = _importlib_util.spec_from_file_location(
    "bvc", os.path.join(SCRIPTS, "build-vocabulary-catalog.py")
)
bvc = _importlib_util.module_from_spec(_SPEC)
assert _SPEC and _SPEC.loader
_SPEC.loader.exec_module(bvc)

REQUIRED_PACKS = ["computing", "medicine", "finance", "law", "engineering", "music"]

# 欄位契約（schema2）
PACK_KEYS = {
    "id", "name", "summary", "sourceName", "sourceURL",
    "licenseName", "licenseURL", "attribution",
    "version", "defaultOn", "seedTerms",
    "termsFile", "termCount", "termsSHA256",
}

# 各 pack 必有的代表性 seed（CONTRACT-V2；只列「來源確實有」的詞）
EXPECTED_SEEDS = {
    "computing":  ["人工智慧", "機器學習", "資料庫", "作業系統"],
    "medicine":   ["心肌梗塞", "高血壓", "糖尿病"],
    "finance":    ["資產負債表", "現金流量", "資本市場"],
    "law":        ["訴訟", "判決"],  # 損害賠償不在來源；不可冒稱
    "engineering": ["鋼筋混凝土", "半導體"],
    "music":      ["麥克風", "混音", "頻率", "音場"],
}

ALLOWED_LICENSE_URLS = {
    "https://terms.naer.edu.tw/mysite/about/2/",
}


class CatalogContract(unittest.TestCase):
    """驗證 catalog.json 結構契約。"""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(CATALOG):
            raise unittest.SkipTest(f"catalog.json 不存在：{CATALOG}；先跑 build-vocabulary-catalog.py")
        with open(CATALOG, encoding="utf-8") as f:
            cls.cat = json.load(f)
        cls.packs = {p["id"]: p for p in cls.cat.get("packs", [])}

    def test_schema_version(self):
        self.assertEqual(self.cat.get("schemaVersion"), 2)

    def test_six_packs_present(self):
        for pid in REQUIRED_PACKS:
            self.assertIn(pid, self.packs, f"缺包：{pid}")

    def test_pack_contract(self):
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                self.assertEqual(pid, pack["id"])
                missing = PACK_KEYS - set(pack.keys())
                self.assertFalse(missing, f"{pid} 缺欄位：{missing}")
                # schema2：catalog 內不得再含 terms 全表
                self.assertNotIn("terms", pack, f"{pid}: schema2 應已移除 terms")
                # id 不可重複
                self.assertIsInstance(pack["id"], str)
                self.assertIsInstance(pack["name"], str)
                self.assertIsInstance(pack["summary"], str)
                self.assertIsInstance(pack["sourceURL"], str)
                self.assertIsInstance(pack["licenseURL"], str)
                self.assertIsInstance(pack["version"], str)
                self.assertIsInstance(pack["defaultOn"], bool)
                self.assertFalse(pack["defaultOn"], f"{pid}: 工單要求 defaultOn=False")
                self.assertIsInstance(pack["seedTerms"], list)
                self.assertIsInstance(pack["termsFile"], str)
                self.assertIsInstance(pack["termCount"], int)
                self.assertIsInstance(pack["termsSHA256"], str)
                self.assertEqual(len(pack["termsSHA256"]), 64, f"{pid}: termsSHA256 應為 64 字 hex")
                # termsFile 限定為 id + '.txt'
                self.assertEqual(pack["termsFile"], f"{pid}.txt", f"{pid}: termsFile 應為 {pid}.txt")

    def test_terms_min_count(self):
        """每包至少 300 個（工單要求）— schema2 從 termCount 與 txt 內容核對"""
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                self.assertGreaterEqual(pack["termCount"], 300,
                                        f"{pid} 只有 {pack['termCount']} 個，少於 300 下限")

    def test_seed_terms_count_range(self):
        """seedTerms 必須在 20–40 範圍內（工單要求）"""
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                n = len(pack["seedTerms"])
                self.assertGreaterEqual(n, 20, f"{pid}: seedTerms={n} < 20")
                self.assertLessEqual(n, 40, f"{pid}: seedTerms={n} > 40")

    def test_seed_terms_are_members(self):
        """seedTerms 必須全部存在於對應 .txt（CONTRACT-V2『從真實詞庫挑』）"""
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                tset = self._load_terms_set(pack["termsFile"])
                for s in pack["seedTerms"]:
                    self.assertIn(s, tset, f"{pid}: seed '{s}' 不在 {pack['termsFile']}")

    def test_seed_terms_no_duplicates(self):
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                self.assertEqual(
                    len(pack["seedTerms"]), len(set(pack["seedTerms"])),
                    f"{pid}: seedTerms 有重複",
                )

    def test_seed_terms_match_expected(self):
        """CONTRACT-V2：seed 必須包含合約點名的代表詞；其餘仍可自行挑選。"""
        for pid, must in EXPECTED_SEEDS.items():
            with self.subTest(pack=pid):
                pack = self.packs[pid]
                missing = [t for t in must if t not in pack["seedTerms"]]
                self.assertFalse(
                    missing,
                    f"{pid}: 合約點名的 seed 缺失 {missing}（若來源沒有請在 PACKS['seedCandidates'] 補上）"
                )

    def test_txt_file_exists_and_format(self):
        """每包 .txt 必須存在、UTF-8、LF、尾 LF"""
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                p = os.path.join(ROOT, "data", "vocabulary", pack["termsFile"])
                self.assertTrue(os.path.exists(p), f"{pid}: {pack['termsFile']} 不存在")
                with open(p, "rb") as f:
                    raw = f.read()
                # 不可有 CRLF
                self.assertNotIn(b"\r\n", raw, f"{pid}: {pack['termsFile']} 含 CRLF（應全 LF）")
                # 不可有 lone CR
                self.assertNotIn(b"\r", raw, f"{pid}: {pack['termsFile']} 含 CR")
                # 必須有尾 LF
                self.assertTrue(raw.endswith(b"\n"), f"{pid}: {pack['termsFile']} 必須以 LF 結尾")
                # 內容以 UTF-8 解碼成功
                text = raw.decode("utf-8")
                lines = text.split("\n")
                # 末元素必為空（因為 trailing \n 會多切一個空字串）
                self.assertEqual(lines[-1], "", f"{pid}: 末行必須為空（trailing LF）")
                words = [ln for ln in lines[:-1] if ln]
                # 行數與 termCount 一致（去重保序）
                self.assertEqual(len(words), pack["termCount"],
                                 f"{pid}: {pack['termsFile']} 行數 {len(words)} ≠ termCount {pack['termCount']}")
                # 詞內不得有空白字元
                self.assertFalse(any(" " in w or "　" in w for w in words),
                                 f"{pid}: {pack['termsFile']} 詞內含空白")
                # 不可有重複
                self.assertEqual(len(words), len(set(words)),
                                 f"{pid}: {pack['termsFile']} 內含重複詞")

    def test_txt_sha256_matches(self):
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                p = os.path.join(ROOT, "data", "vocabulary", pack["termsFile"])
                with open(p, "rb") as f:
                    raw = f.read()
                import hashlib
                sha = hashlib.sha256(raw).hexdigest()
                self.assertEqual(sha, pack["termsSHA256"],
                                 f"{pid}: {pack['termsFile']} sha256 與 metadata 不一致")

    def test_txt_terms_length_bounds(self):
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                words = self._load_terms_list(pack["termsFile"])
                too_short = [w for w in words if len(w) < 2]
                too_long = [w for w in words if len(w) > 40]
                self.assertFalse(too_short, f"{pid}: {len(too_short)} 個詞長度 <2")
                self.assertFalse(too_long, f"{pid}: {len(too_long)} 個詞長度 >40")

    def test_txt_terms_no_html_or_control(self):
        ctrl = re.compile(r"[\x00-\x08\x0b\x0e-\x1f\x7f]")
        tag = re.compile(r"<[^>]+>")
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                words = self._load_terms_list(pack["termsFile"])
                self.assertFalse([w for w in words if ctrl.search(w)], f"{pid}: 含控制字元")
                self.assertFalse([w for w in words if tag.search(w)], f"{pid}: 含 HTML 標籤")

    def test_txt_terms_contain_cjk(self):
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                words = self._load_terms_list(pack["termsFile"])
                bad = [w for w in words if not bvc._has_cjk(w)]
                self.assertFalse(bad, f"{pid}: {len(bad)} 個不含 CJK")

    def test_no_code_fragments(self):
        """CONTRACT-V2：拒絕『數字/字母)+』與不平衡括號等破壞片段。"""
        bad_pat = re.compile(r"^[A-Za-z0-9]+\)")
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                words = self._load_terms_list(pack["termsFile"])
                leftovers = [w for w in words if bad_pat.match(w)]
                self.assertFalse(leftovers, f"{pid}: 殘留編號片段 {leftovers[:5]}")

    def test_license_urls_are_naer_statement(self):
        """CONTRACT-V2：不得冒稱 OGDL；licenseURL 必須是樂詞網自身的開放宣告頁。"""
        for pid, pack in self.packs.items():
            with self.subTest(pack=pid):
                self.assertIn(pack["licenseURL"], ALLOWED_LICENSE_URLS,
                              f"{pid}: licenseURL 不在白名單（CONTRACT-V2 禁止通用 OGDL）")
                self.assertTrue(pack["sourceURL"].startswith("https://"),
                                f"{pid}: sourceURL 不是 https://")

    def _load_terms_set(self, terms_file: str) -> set[str]:
        words = self._load_terms_list(terms_file)
        return set(words)

    def _load_terms_list(self, terms_file: str) -> list[str]:
        p = os.path.join(ROOT, "data", "vocabulary", terms_file)
        with open(p, encoding="utf-8") as f:
            text = f.read()
        lines = text.split("\n")
        # trailing LF → 末元素為空
        return [ln for ln in lines[:-1] if ln]


class NoticeContract(unittest.TestCase):
    """驗證 NOTICE.md 內容必含授權/顯名/sha256（schema2）。"""

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(NOTICE):
            raise unittest.SkipTest(f"NOTICE.md 不存在：{NOTICE}")
        with open(NOTICE, encoding="utf-8") as f:
            cls.text = f.read()

    def test_contains_naer_statement_url(self):
        """CONTRACT-V2：授權必須指向樂詞網自身的開放宣告頁。"""
        self.assertIn("terms.naer.edu.tw/mysite/about/2/", self.text)

    def test_mentions_not_ogdl(self):
        """CONTRACT-V2：不能把通用 OGDL 當唯一授權。"""
        # 允許『並非 OGDL』之類對照說明，但不允許把 OGDL 當唯一授權
        self.assertIn("OGDL", self.text)  # 必須對照說明
        # 不應把 OGDL 描述為主要授權依據
        self.assertIn("並非", self.text)  # 明示兩者不同

    def test_contains_source_url(self):
        self.assertIn("terms.naer.edu.tw/download", self.text)

    def test_contains_attribution(self):
        self.assertIn("國家教育研究院", self.text)

    def test_contains_sha256_markers(self):
        self.assertIn("sha256", self.text.lower())

    def test_contains_cleaning_rules(self):
        self.assertIn("清洗規則", self.text)


class BuildCleanerUnit(unittest.TestCase):
    """驗證 build script 的純清洗函式。"""

    def test_clean_terms_basic(self):
        out = bvc.clean_terms("音樂名詞")
        self.assertEqual(out, ["音樂名詞"])

    def test_clean_terms_html(self):
        # clean_terms 接收的應該是 _strip_text 後的字串（已去 HTML）；模擬之
        out = bvc.clean_terms(bvc._strip_text("<p>罪刑法定原則</p>"))
        self.assertEqual(out, ["罪刑法定原則"])

    def test_clean_terms_split_by_semicolon(self):
        out = bvc.clean_terms("罪刑法定原則；罪刑法定主義")
        self.assertEqual(out, ["罪刑法定原則", "罪刑法定主義"])

    def test_clean_terms_strip_paren_explanation(self):
        out = bvc.clean_terms("紅斑（紫外放射光）")
        self.assertEqual(out, ["紅斑"])

    def test_clean_terms_strip_white_corner(self):
        out = bvc.clean_terms("﹝電磁﹞放射")
        self.assertEqual(out, ["放射"])

    def test_clean_terms_skip_short(self):
        self.assertEqual(bvc.clean_terms("的"), [])
        self.assertEqual(bvc.clean_terms(""), [])

    def test_clean_terms_skip_long(self):
        long_term = "甲" * 50
        self.assertEqual(bvc.clean_terms(long_term), [])

    def test_clean_terms_skip_english_only(self):
        self.assertEqual(bvc.clean_terms("foo"), [])
        self.assertEqual(bvc.clean_terms("4K"), [])

    def test_clean_terms_skip_lone_paren(self):
        # CONTRACT-V2/FINDING-2：尾端孤立右括號不應被靜默吃掉變合法假詞；
        # 視為破壞片段，整段拒絕。
        self.assertEqual(bvc.clean_terms("勾股定理）"), [])

    def test_clean_terms_skip_paren_lead(self):
        self.assertEqual(bvc.clean_terms("（註解）"), [])

    # ---------- Finding 2：括號感知 oracle ----------
    def test_clean_terms_paren_then_split_keeps_main(self):
        # 期望：僅保留『音訊』；『英語』『註解』在括號內，不當詞
        self.assertEqual(bvc.clean_terms("音訊（英語,註解）"), ["音訊"])

    def test_clean_terms_paren_with_semis_inside(self):
        # 期望：僅保留『類型』；註解分號在括號內
        self.assertEqual(bvc.clean_terms("類型（註解；人工）"), ["類型"])

    def test_clean_terms_mixed_two_terms(self):
        # 期望：保留兩個主詞
        self.assertEqual(
            bvc.clean_terms("音訊（英語,註解）；類型（註解）"),
            ["音訊", "類型"],
        )

    def test_clean_terms_truly_unbalanced_rejected(self):
        # 不平衡 → 整段拒絕（即使文字部分合理）
        self.assertEqual(bvc.clean_terms("音訊（英語"), [])
        self.assertEqual(bvc.clean_terms("音訊英語）"), [])

    def test_clean_terms_nested_brackets(self):
        # 嵌套括號：剝外層後內層仍在，視為註解整段丟
        self.assertEqual(bvc.clean_terms("音訊（外（內容）層）"), ["音訊"])

    def test_split_top_level_respects_depth(self):
        # 僅在 depth==0 才切；括號內的分隔符不算
        self.assertEqual(
            bvc._split_top_level("音訊（英語,註解）；類型", ";,；，"),
            ["音訊（英語,註解）", "類型"],
        )

    def test_strip_brackets_pairs(self):
        self.assertEqual(bvc._strip_brackets("紅斑（紫外放射光）"), "紅斑")
        self.assertEqual(bvc._strip_brackets("音訊（英語,註解）"), "音訊")
        self.assertEqual(bvc._strip_brackets("音訊"), "音訊")
        self.assertEqual(bvc._strip_brackets("音訊（英語"), "音訊（英語")  # 不平衡：原樣

    # ---------- Finding 1：nested span fixture ----------
    def test_cell_text_nested_span_no_duplication(self):
        # 合成 cell：<text:p>人工<text:span>智慧</text:span></text:p>
        # 期望：cell_text 輸出『人工智慧』，不再重複『智慧』
        ns_office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
        ns_table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        ns_text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        xml = (
            f'<table:table-cell xmlns:table="{ns_table}" xmlns:text="{ns_text}">'
            '<text:p>人工<text:span>智慧</text:span></text:p>'
            '</table:table-cell>'
        )
        cell = ET.fromstring(xml)
        out = bvc._cell_text(cell)
        self.assertEqual(out, "人工智慧", f"nested span 重複追加：{out!r}")
        # 確保 clean_terms 通過（不會因內部空白被踢掉）
        self.assertEqual(bvc.clean_terms(out), ["人工智慧"])

    def test_cell_text_text_s_and_tail(self):
        # text:s text:c="3" → 3 個空白；span 的 tail 是接續字元
        # _strip_text 會把連續空白合併成單一半形空白
        ns_table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
        ns_text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
        xml = (
            f'<table:table-cell xmlns:table="{ns_table}" xmlns:text="{ns_text}">'
            '<text:p>前<text:s text:c="3"/>後<text:span>尾</text:span><text:s/>續</text:p>'
            '</table:table-cell>'
        )
        cell = ET.fromstring(xml)
        out = bvc._cell_text(cell)
        self.assertEqual(out, "前 後尾 續",
                         f"text:s 與 span tail 應正確展開：{out!r}")

    # ---------- Finding 4：sources.json ----------
    def test_sources_json_loadable(self):
        # sources.json 必須在 repo 正本，且可被腳本讀
        path = os.path.join(ROOT, "data", "vocabulary", "sources.json")
        self.assertTrue(os.path.exists(path), f"sources.json 不存在：{path}")
        sources = bvc.load_sources(path)
        self.assertGreater(len(sources), 0)
        for fn, info in sources.items():
            self.assertIn("url", info)
            self.assertIn("sha256", info)
            self.assertEqual(len(info["sha256"]), 64)

    # ---------- Finding 5：刪死碼檢查 ----------
    def test_no_dead_code_imports(self):
        # csv 已從 import 拿掉
        with open(os.path.join(SCRIPTS, "build-vocabulary-catalog.py"), encoding="utf-8") as f:
            src = f.read()
        self.assertNotIn("import csv\n", src)
        self.assertNotIn("if False else None", src)

    def test_strip_text_strips_html(self):
        s = bvc._strip_text("<p>X<BR>Y</p>")
        self.assertNotIn("<", s)
        self.assertIn("X", s)
        self.assertIn("Y", s)

    def test_strip_text_unescapes_entities(self):
        s = bvc._strip_text("A&amp;B")
        self.assertIn("&", s)


class BuildReconstruction(unittest.TestCase):
    """驗證 build script 從 raw cache 重建後欄位形狀一致（不含真實下載）。"""

    def setUp(self):
        # 建一個臨時 raw-dir，裡面放一個假 ODS（與 NAER 真實結構一致）
        self.tmp = tempfile.mkdtemp()
        # build a minimal valid ODS zip-of-zip
        self.ods_path = self._make_minimal_ods(self.tmp, rows=[
            ("ID", "英文名稱", "中文名稱", "圖片"),
            ("1", "alpha", "音樂", ""),
            ("2", "beta", "音樂學；音樂研究", ""),
            ("3", "gamma", "紅斑（紫外放射光）", ""),
            ("4", "delta", "7) 碼", ""),         # 應被丟（CONTRACT-V2 編號片段）
            ("5", "epsilon", "的", ""),            # 應被丟（太短）
            ("6", "zeta", "<p>古典樂</p>", ""),
            ("7", "eta", "A B C", ""),            # 純英文 → 應被丟
            ("8", "theta", "音符", ""),
            ("9", "iota", ".AFM 格式", ""),       # 應被丟（CONTRACT-V2 短副檔名）
            ("10", "kappa", "a+b=c 公式", ""),    # 應被丟（CONTRACT-V2 公式）
            ("11", "lambda", "心肌梗塞", ""),      # 應保留（CONTRACT-V2 期望 seed）
        ])
        self.zip_path = os.path.join(self.tmp, "fake_pack.zip")
        with zipfile.ZipFile(self.zip_path, "w") as z:
            z.write(self.ods_path, arcname="fake_0.ods")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _make_minimal_ods(self, tmp, rows):
        # Build a minimal content.xml that mimics NAER's structure
        ns = 'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"'
        cells = []
        for row in rows:
            cells.append("<table:table-row>" + "".join(
                f'<table:table-cell office:value-type="string"><text:p>{c}</text:p></table:table-cell>'
                for c in row
            ) + "</table:table-row>")
        xml = f'<?xml version="1.0" encoding="UTF-8"?>\n<office:document-content {ns}><office:body><office:spreadsheet><table:table table:name="Sheet1">{"".join(cells)}</table:table></office:spreadsheet></office:body></office:document-content>'

        ods_path = os.path.join(tmp, "fake.ods")
        # ODS is a zip containing mimetype, META-INF/manifest.xml, content.xml
        with zipfile.ZipFile(ods_path, "w") as z:
            z.writestr("mimetype", "application/vnd.oasis.opendocument.spreadsheet")
            z.writestr("META-INF/manifest.xml",
                       '<?xml version="1.0" encoding="UTF-8"?><manifest:manifest '
                       'xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0">'
                       '<manifest:file-entry media-type="application/vnd.oasis.opendocument.spreadsheet" '
                       'full-path="/"/><manifest:file-entry media-type="text/xml" full-path="content.xml"/>'
                       '</manifest:manifest>')
            z.writestr("content.xml", xml)
        return ods_path

    def test_parse_ods_returns_rows(self):
        rows = bvc.parse_ods(self.ods_path)
        header, data = rows
        self.assertEqual(header[2], "中文名稱")
        expected = [
            ("1", "alpha", "音樂", ""),
            ("2", "beta", "音樂學；音樂研究", ""),
            ("3", "gamma", "紅斑（紫外放射光）", ""),
            ("4", "delta", "7) 碼", ""),
            ("5", "epsilon", "的", ""),
            ("6", "zeta", "<p>古典樂</p>", ""),
            ("7", "eta", "A B C", ""),
            ("8", "theta", "音符", ""),
            ("9", "iota", ".AFM 格式", ""),
            ("10", "kappa", "a+b=c 公式", ""),
            ("11", "lambda", "心肌梗塞", ""),
        ]
        self.assertEqual(len(data), len(expected))

    def test_extract_terms_from_fixture(self):
        terms, info = bvc.extract_terms_from_zip(self.tmp, "fake_pack.zip")
        # 期望保留：音樂, 音樂學, 音樂研究, 古典樂, 音符, 心肌梗塞
        # 期望丟棄：7) 碼（編號片段）、的（太短）、A B C（純英數）、
        #           .AFM 格式（短副檔名）、a+b=c 公式（公式片段）
        for must in ["音樂學", "音樂研究", "古典樂", "音符", "心肌梗塞"]:
            self.assertIn(must, terms, f"應保留：{must}")
        for must_not in ["7) 碼", "的", "A B C", ".AFM 格式", "a+b=c 公式"]:
            self.assertNotIn(must_not, terms, f"不應出現：{must_not}")

    def test_seed_in_terms(self):
        # select_seeds 新契約：傳入 term_set 與 curated candidates
        terms, _ = bvc.extract_terms_from_zip(self.tmp, "fake_pack.zip")
        seeds = bvc.select_seeds(set(terms), ["心肌梗塞", "音符", "不存在"])
        for s in seeds:
            self.assertIn(s, terms)
        self.assertNotIn("不存在", seeds)

    def test_write_terms_txt_format(self):
        """驗證 schema2 txt 寫入：UTF-8、LF、尾 LF、單詞/行。"""
        terms, _ = bvc.extract_terms_from_zip(self.tmp, "fake_pack.zip")
        out = os.path.join(self.tmp, "out.txt")
        sha = bvc.write_terms_txt(out, terms)
        with open(out, "rb") as f:
            raw = f.read()
        self.assertNotIn(b"\r", raw, "不得含 CR")
        self.assertTrue(raw.endswith(b"\n"), "必須以 LF 結尾")
        text = raw.decode("utf-8")
        lines = text.split("\n")
        self.assertEqual(lines[-1], "", "末行必須為空（trailing LF）")
        self.assertEqual(len([ln for ln in lines[:-1] if ln]), len(terms))
        # SHA256 與檔案內容一致
        import hashlib
        self.assertEqual(sha, hashlib.sha256(raw).hexdigest())


class IdAndConsistency(unittest.TestCase):
    """驗證 pack id 不變、與 PACKS 定義一致。"""

    def test_pack_ids_match_definition(self):
        defined_ids = {p["id"] for p in bvc.PACKS}
        self.assertEqual(defined_ids, set(REQUIRED_PACKS))

    def test_all_packs_have_source_url(self):
        # schema2：source/license 為 module-level 常數
        self.assertTrue(bvc.SOURCE_URL.startswith("https://"))
        self.assertTrue(bvc.LICENSE_URL.startswith("https://"))


class DeltaFixRegression(unittest.TestCase):
    """DELTA-FIX 對應的目標化回歸檢查（僅 fail-closed 與可重現日期兩項）。"""

    def test_sources_missing_path_fails_closed(self):
        """DELTA-FIX #1：--sources 指向不存在的路徑必須 SystemExit，不靜默放行。"""
        import subprocess
        # 用一個明顯不存在 / 不是檔案的路徑觸發 fail-closed
        cmd = [
            sys.executable,
            os.path.join(SCRIPTS, "build-vocabulary-catalog.py"),
            "--raw-dir", "/tmp",
            "--out-dir", "/tmp/__no_out",
            "--sources", "/nonexistent/path/sources.json",
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0, f"應 fail-closed；實際 rc={r.returncode}\nstdout={r.stdout}\nstderr={r.stderr}")

    def test_sources_malformed_json_fails_closed(self):
        """DELTA-FIX #1：sources.json 不是合法 list → SystemExit。"""
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"not": "a list"}')
            bad = f.name
        try:
            cmd = [
                sys.executable,
                os.path.join(SCRIPTS, "build-vocabulary-catalog.py"),
                "--raw-dir", "/tmp",
                "--out-dir", "/tmp/__no_out",
                "--sources", bad,
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, f"應 fail-closed；rc={r.returncode}")
            self.assertIn("list", r.stderr + r.stdout, "應提示 sources.json 必須是 list")
        finally:
            os.unlink(bad)

    def test_sources_missing_sha256_field_fails_closed(self):
        """DELTA-FIX #1：任一筆缺 sha256 或 sha256 不是 64 字 hex → SystemExit。"""
        import subprocess, tempfile, json
        bad_payload = [{
            "filename": "x.zip",
            "url": "https://example.com/x.zip",
            "sha256": "tooshort",
        }]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(bad_payload, f)
            bad = f.name
        try:
            cmd = [
                sys.executable,
                os.path.join(SCRIPTS, "build-vocabulary-catalog.py"),
                "--raw-dir", "/tmp",
                "--out-dir", "/tmp/__no_out",
                "--sources", bad,
            ]
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, f"應 fail-closed；rc={r.returncode}")
        finally:
            os.unlink(bad)

    def test_load_sources_rejects_non_list(self):
        """DELTA-FIX #1：load_sources 直接驗證 — 非 list → SystemExit。"""
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write('{"a":1}')
            bad = f.name
        try:
            with self.assertRaises(SystemExit):
                bvc.load_sources(bad)
        finally:
            os.unlink(bad)

    def test_load_sources_rejects_missing_filename(self):
        import subprocess, tempfile, json
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump([{"url": "https://x", "sha256": "0"*64}], f)
            bad = f.name
        try:
            with self.assertRaises(SystemExit):
                bvc.load_sources(bad)
        finally:
            os.unlink(bad)

    def test_version_constant_pinned(self):
        """DELTA-FIX #2：VERSION 是固定日期字串，不是 date.today()。"""
        self.assertEqual(bvc.VERSION, "2026-09-20")
        # 防誤把 dt.date.today() 寫回去
        import inspect
        src = inspect.getsource(bvc)
        self.assertNotIn("dt.date.today()", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)