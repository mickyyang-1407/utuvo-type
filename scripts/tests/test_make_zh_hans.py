#!/usr/bin/env python3
"""test_make_zh_hans — make-zh-hans.py 不准弄丟已翻好的 zh-Hans。

2026-09-26：key 沒有中文的條目（vocab.pack.*.name 這種 manual 動態 key、"Google Gemini"、"%@・%@"）
被 fill() 標成 shouldTranslate=false 並刪掉 zh-Hans，简中使用者會看到繁體詞庫名。
純 stdlib；只用記憶體 fixture 與暫存檔，不跑 xcodebuild／xcstringstool。

跑法：python3 scripts/tests/test_make_zh_hans.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "make-zh-hans.py")

_spec = importlib.util.spec_from_file_location("make_zh_hans", SCRIPT)
mzh = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mzh)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def fixture() -> dict:
    return {
        "vocab.pack.law.name": {
            "extractionState": "manual",
            "localizations": {"zh-Hant": unit("法律"), "zh-Hans": unit("法律")},
        },
        "vocab.pack.music.name": {  # manual、還沒翻：原文要取 zh-Hant 值，不是 key
            "extractionState": "manual",
            "localizations": {"zh-Hant": unit("音樂與音響")},
        },
        "Google Gemini": {"localizations": {"zh-Hans": unit("Google Gemini")}},
        "%@・%@": {"extractionState": "manual",
                   "localizations": {"zh-Hant": unit("%@・%@"), "zh-Hans": unit("%@・%@")}},
        "%lld": {},  # 純格式、沒人翻過：照舊標 shouldTranslate=false
        "設定": {},
    }


class FillKeepsManualTranslations(unittest.TestCase):
    def setUp(self):
        self.entries = fixture()
        mzh.fill(self.entries, mzh.localizable_source, force=False)

    def zh_hans(self, key):
        return self.entries[key].get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {}).get("value")

    def test_manual_non_cjk_key_keeps_zh_hans(self):
        self.assertEqual(self.zh_hans("vocab.pack.law.name"), "法律")
        self.assertNotIn("shouldTranslate", self.entries["vocab.pack.law.name"])

    def test_manual_untranslated_uses_zh_hant_value_as_source(self):
        self.assertEqual(self.zh_hans("vocab.pack.music.name"), "音乐与音响")

    def test_hand_given_non_cjk_translation_kept(self):
        for key in ("Google Gemini", "%@・%@"):
            self.assertIsNotNone(self.zh_hans(key), key)
            self.assertNotIn("shouldTranslate", self.entries[key], key)

    def test_pure_format_still_marked_no_translate(self):
        self.assertIs(self.entries["%lld"].get("shouldTranslate"), False)
        self.assertEqual(self.zh_hans("設定"), "设置")

    def test_nothing_lost_vs_fixture(self):
        self.assertEqual(mzh.lost_units(mzh.target_units(fixture()), self.entries), [])


class GuardAndRestore(unittest.TestCase):
    def test_lost_units_detects_stripped_and_deleted(self):
        base = mzh.target_units(fixture())
        now = fixture()
        now["Google Gemini"] = {"shouldTranslate": False}          # 被清成不翻
        del now["vocab.pack.law.name"]                              # 整個 key 被 sync 刪掉
        self.assertEqual(mzh.lost_units(base, now), ["Google Gemini", "vocab.pack.law.name"])

    def test_restore_brings_back_unit_and_drops_should_translate(self):
        base = mzh.target_units(fixture())
        now = fixture()
        now["Google Gemini"] = {"shouldTranslate": False}
        self.assertEqual(mzh.restore_units(base, now), ["Google Gemini"])
        self.assertEqual(now["Google Gemini"], {"localizations": {"zh-Hans": unit("Google Gemini")}})
        self.assertEqual(mzh.lost_units(base, now), [])


class CheckCli(unittest.TestCase):
    """--check 對著一份「比現在多一條 zh-Hans」的 baseline 要紅；對著自己要綠。"""

    def run_check(self, baseline: dict) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile("w", suffix=".xcstrings", delete=False, encoding="utf-8") as f:
            json.dump(baseline, f, ensure_ascii=False)
        try:
            return subprocess.run([sys.executable, SCRIPT, "--check", "--baseline", f.name],
                                  capture_output=True, text=True)
        finally:
            os.unlink(f.name)

    def test_red_when_baseline_has_extra_translation(self):
        current = mzh.load(mzh.CATALOG)
        # baseline 多一條有 zh-Hans 的 key＝現在的 catalog 把它弄丟了。
        current["strings"]["__synthetic_lost_key__"] = {"localizations": {"zh-Hans": unit("假的")}}
        proc = self.run_check(current)
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn("zh-Hans 消失：ios/Shared/Localizable.xcstrings  __synthetic_lost_key__", proc.stdout)

    def test_green_against_itself(self):
        proc = self.run_check(mzh.load(mzh.CATALOG))
        self.assertEqual(proc.returncode, 0, proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
