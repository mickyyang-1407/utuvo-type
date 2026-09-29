#!/usr/bin/env python3
"""編出 Android 英文鍵盤建議列用的 `english-words.txt`（補完與拼字建議的詞表）。

為什麼需要：iOS 的 UITextChecker 同時給「補完」與「拼錯的建議」，而且永遠在；Android 的系統拼字服務
（SpellCheckerSession，通常是 Gboard 的）只做改錯、不做補完，而且 Gboard 字典沒載入時對每個字都回
「在字典裡、零建議」（2026-09-29 模擬器實測 Tomor 一個建議都沒有）。所以 Android 內附一份詞表。

用法：
    python3 scripts/build-english-words.py <解開的 scowl-2020.12.07 目錄> [--output 路徑] [--check]

資料來源與授權
--------------
SCOWL 2020.12.07（Kevin Atkinson，http://wordlist.aspell.net/）：
    https://downloads.sourceforge.net/project/wordlist/SCOWL/2020.12.07/scowl-2020.12.07.tar.gz
    sha256 5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc
授權是「保留版權聲明即可使用、修改、散布」的寬鬆授權（全文見 THIRD_PARTY_NOTICES.md）；
10 級主要來自 Moby Words II 與 Brian Kelk 的 UK 詞頻表，兩者都是 public domain。

取哪些：`final/` 裡 english／american 的 words、upper（專有名詞如 Monday、English）、contractions，
大小級 ≤ 50（SCOWL 建議的一般拼字檢查大小）。只留純 ASCII 字母加撇號的字。

排序（檔案一行一個字，**行號就是排名**，越前面越常用）：
SCOWL 的大小級就是常用度分級（10 最常用）；同一級裡字短的在前、再依字母序——不自己發明頻率。
同一個字（不分大小寫）只留最常用那一級的第一個寫法。
"""
import argparse
import hashlib
import pathlib
import re
import sys

LEVELS = (10, 20, 35, 40, 50)
KINDS = ("words", "upper", "contractions")
VARIANTS = ("english", "american")
WORD = re.compile(r"^[A-Za-z]+(?:'[A-Za-z]+)*$")


def build(scowl: pathlib.Path) -> list[str]:
    final = scowl / "final"
    if not final.is_dir():
        sys.exit(f"找不到 {final}（要給解開的 scowl 目錄）")
    ranked: list[tuple[int, int, str, str]] = []
    for level in LEVELS:
        for variant in VARIANTS:
            for kind in KINDS:
                path = final / f"{variant}-{kind}.{level}"
                if not path.exists():
                    continue
                for raw in path.read_bytes().decode("latin-1").splitlines():
                    w = raw.strip()
                    if WORD.match(w):
                        ranked.append((level, len(w), w.lower(), w))
    ranked.sort()
    out, seen = [], set()
    for _, _, lower, w in ranked:
        if lower in seen:
            continue
        seen.add(lower)
        out.append(w)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("scowl", type=pathlib.Path)
    root = pathlib.Path(__file__).resolve().parent.parent
    ap.add_argument("--output", type=pathlib.Path,
                    default=root / "android/app/src/main/assets/english-words.txt")
    ap.add_argument("--check", action="store_true", help="只比對既有檔案是否與重建結果相同")
    args = ap.parse_args()
    text = "\n".join(build(args.scowl)) + "\n"
    if args.check:
        same = args.output.exists() and args.output.read_text() == text
        print("same" if same else "DIFFERENT")
        sys.exit(0 if same else 1)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)
    print(f"{args.output}: {text.count(chr(10))} words, sha256 {hashlib.sha256(text.encode()).hexdigest()}")


if __name__ == "__main__":
    main()
